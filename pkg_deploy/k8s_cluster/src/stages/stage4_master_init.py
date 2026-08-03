"""
Stage 4: Master 节点集群初始化

执行 kubeadm init：
- 生成 kubeadm 初始化配置文件
- 执行 kubeadm init
- 配置 kubectl（admin.conf → ~/.kube/config）
- 保存 join token 供后续 Node 加入使用
- 移除 Master 节点污点（如配置要求可调度）
- 安装后扫描验证集群状态
"""

import os
import sys
import time

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.workflow_state import WorkflowStateManager
from common.yaml_helper import YAMLHelper
from common.ssh_client import SSHClient
from src.workflow.workflow_exception import MasterInitError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "config")
# MODULE_DIR = pkg_deploy/k8s_cluster/  (从 src/stages/ 回退三层)
MODULE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
TEMP_CACHE_DIR = os.path.join(MODULE_DIR, "runtime", "temp_cache")
IMAGES_DIR = os.path.join(MODULE_DIR, "images")


def _is_master_initialized(ssh: SSHClient) -> bool:
    """检查 Master 是否已经初始化（幂等检测）。"""
    # 检查 admin.conf 存在且 apiserver 响应
    _, out, _ = ssh.exec_command(
        "test -f /etc/kubernetes/admin.conf && "
        "kubectl --kubeconfig=/etc/kubernetes/admin.conf get node "
        "--no-headers 2>/dev/null | grep -c ' Ready' || echo 0",
        sudo=False, timeout=10
    )
    count = int((out.strip() or "0").splitlines()[0])
    if count > 0:
        logger.info(f"检测到已初始化的集群 ({count} 个 Ready 节点)，跳过 kubeadm init")
        return True
    return False


def _cleanup_partial_init(ssh: SSHClient, hostname: str) -> bool:
    """检测并清理 kubeadm init 半残状态（如 PKI 不完整、admin.conf 缺失、API Server 宕机）。
    返回 True 表示已执行清理，需重新 init。
    """
    _, admin_ok, _ = ssh.exec_command("test -f /etc/kubernetes/admin.conf && echo YES || echo NO", timeout=5)
    _, pki_ok, _ = ssh.exec_command("test -d /etc/kubernetes/pki -a -f /etc/kubernetes/pki/ca.crt && echo YES || echo NO", timeout=5)
    _, etcd_ok, _ = ssh.exec_command("test -d /var/lib/etcd/member && echo YES || echo NO", timeout=5)
    _, apiserver_ok, _ = ssh.exec_command(
        "kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw /healthz 2>/dev/null | grep -q ok && echo YES || echo NO",
        timeout=5
    )
    admin_ok = admin_ok.strip()
    pki_ok = pki_ok.strip()
    etcd_ok = etcd_ok.strip()
    apiserver_ok = apiserver_ok.strip()

    need_reset = False
    reason = ""

    # 情况1: PKI 存在但 admin.conf 缺失 → 半残
    if "YES" in pki_ok and "NO" in admin_ok:
        need_reset = True
        reason = "PKI 存在但 admin.conf 缺失"
    # 情况2: admin.conf 存在但 API Server 不响应
    elif "YES" in admin_ok and "NO" in apiserver_ok:
        need_reset = True
        reason = "admin.conf 存在但 API Server 不响应"
    # 情况3: etcd 数据存在但 admin.conf 缺失
    elif "YES" in etcd_ok and "NO" in admin_ok:
        need_reset = True
        reason = "etcd 数据存在但 admin.conf 缺失"
    # 情况4: 任何 K8s 残留但 kubelet 已停止
    elif "YES" in pki_ok or "YES" in etcd_ok:
        _, kubelet, _ = ssh.exec_command("systemctl is-active kubelet 2>/dev/null || echo INACTIVE", timeout=5)
        if "INACTIVE" in kubelet:
            need_reset = True
            reason = "K8s 残留文件存在且 kubelet 已停止"

    if need_reset:
        logger.warning(f"[{hostname}] 检测到半残状态({reason})，自动 kubeadm reset...")
        ssh.exec_command(
            "kubeadm reset --force --cri-socket=unix:///var/run/containerd/containerd.sock 2>&1 || true; "
            "rm -rf /etc/kubernetes/ /var/lib/kubelet/ /var/lib/etcd/ /root/.kube/ 2>/dev/null || true",
            sudo=False, timeout=120
        )
        return True
    return False


def _verify_master(ssh: SSHClient, hostname: str, expected_version: str) -> None:
    """安装后扫描验证 Master 节点和集群状态。参考 stage2/stage3 验证模式。"""
    logger.info(f"[{hostname}] 安装后扫描验证...")
    checks = []
    expected_ver = expected_version.lstrip("v")
    admin_conf = "/etc/kubernetes/admin.conf"
    kubectl = f"kubectl --kubeconfig={admin_conf}"

    # 1. admin.conf 存在
    _, out, _ = ssh.exec_command(f"test -f {admin_conf} && echo YES || echo NO")
    if "YES" in out:
        checks.append(("admin.conf", "PASS", "已生成"))
    else:
        checks.append(("admin.conf", "FAIL", "缺失"))
        # 无 admin.conf，后续检查无法执行，直接输出汇总
        _print_verify_summary(checks)
        raise MasterInitError(hostname, "admin.conf 未生成")

    # 2. API Server 健康检查
    _, apiserver, _ = ssh.exec_command(
        f"{kubectl} get --raw /healthz 2>/dev/null || echo FAILED", timeout=10
    )
    if "ok" in apiserver:
        checks.append(("API Server", "PASS", "healthz=ok"))
    else:
        checks.append(("API Server", "FAIL", apiserver.strip()[:60]))

    # 3. API Server /livez
    _, livez, _ = ssh.exec_command(
        f"{kubectl} get --raw /livez 2>/dev/null || echo FAILED", timeout=10
    )
    if "ok" in livez:
        checks.append(("API /livez", "PASS", "ok"))
    else:
        checks.append(("API /livez", "WARN", livez.strip()[:60]))

    # 4. 节点 Ready 状态
    _, node_out, _ = ssh.exec_command(
        f"{kubectl} get node --no-headers 2>/dev/null || echo 'NONE'", timeout=10
    )
    if "Ready" in node_out:
        ready_cnt = node_out.count("Ready")
        total_cnt = len([l for l in node_out.strip().split("\n") if l.strip()])
        checks.append(("节点就绪", "PASS", f"{ready_cnt}/{total_cnt} Ready"))
    else:
        checks.append(("节点就绪", "FAIL", "无 Ready 节点"))

    # 5. K8s Server 版本
    _, ver_out, _ = ssh.exec_command(
        f"{kubectl} version -o json 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d.get('serverVersion',{{}}).get('gitVersion',''))\" 2>/dev/null || echo NONE",
        timeout=10
    )
    server_ver = ver_out.strip().lstrip("v")
    if server_ver and server_ver != "NONE":
        status = "PASS" if server_ver == expected_ver else "WARN"
        checks.append(("Server版本", status, f"v{server_ver} (期望 v{expected_ver})"))
    else:
        checks.append(("Server版本", "WARN", "无法获取"))

    # 6. 系统组件 Pod 状态 (kube-system namespace)
    _, pod_out, _ = ssh.exec_command(
        f"{kubectl} get pod -n kube-system --no-headers 2>/dev/null || echo NONE", timeout=15
    )
    if pod_out.strip() != "NONE":
        total_pods = len([l for l in pod_out.strip().split("\n") if l.strip()])
        running = pod_out.count("Running")
        completed = pod_out.count("Completed")
        ok_count = running + completed
        if total_pods > 0:
            status = "PASS" if ok_count == total_pods else "WARN"
            checks.append(("系统组件", status, f"{ok_count}/{total_pods} Running/Completed"))
        else:
            checks.append(("系统组件", "WARN", "无 pod"))
    else:
        checks.append(("系统组件", "FAIL", "无法获取"))

    # 7. etcd 健康检查
    _, etcd_health, _ = ssh.exec_command(
        f"{kubectl} get --raw=/healthz/etcd 2>/dev/null || echo FAILED", timeout=10
    )
    if "ok" in etcd_health:
        checks.append(("etcd", "PASS", "healthz=ok"))
    else:
        checks.append(("etcd", "WARN", etcd_health.strip()[:60]))

    # 8. kubelet 服务状态
    _, kls, _ = ssh.exec_command("systemctl is-active kubelet 2>/dev/null || echo NONE")
    if "active" in kls:
        checks.append(("kubelet", "PASS", "active"))
    else:
        checks.append(("kubelet", "FAIL", kls.strip()))

    # 9. kubelet 开机自启
    _, enabled, _ = ssh.exec_command("systemctl is-enabled kubelet 2>/dev/null || echo NONE")
    if "enabled" in enabled:
        checks.append(("kubelet自启", "PASS", "enabled"))
    else:
        # kubeadm init 不会自动 enable kubelet，属正常现象
        checks.append(("kubelet自启", "WARN", "未 enable（kubeadm 默认行为）"))

    # 10. 证书到期检查（确认证书已生成且有效期合理）
    _, certs, _ = ssh.exec_command(
        f"{kubectl} get secret -n kube-system 2>/dev/null | grep -c 'cert' || echo 0",
        timeout=10
    )
    cert_count = int((certs.strip() or "0").splitlines()[0])
    if cert_count > 0:
        checks.append(("证书/Secret", "PASS", f"{cert_count} 个"))
    else:
        checks.append(("证书/Secret", "WARN", "未找到"))

    _print_verify_summary(checks)

    failed = sum(1 for _, r, _ in checks if r == "FAIL")
    if failed > 0:
        raise MasterInitError(hostname, f"集群验证 {failed} 项未通过")


def _print_verify_summary(checks: list) -> None:
    """输出验证结果汇总。"""
    total = len(checks)
    passed = sum(1 for _, r, _ in checks if r == "PASS")
    warned = sum(1 for _, r, _ in checks if r == "WARN")
    failed = sum(1 for _, r, _ in checks if r == "FAIL")
    logger.info(f"  {'─' * 50}")
    for name, result, detail in checks:
        if result == "PASS":
            logger.info(f"  [PASS] {name:14s}: {detail}")
        elif result == "WARN":
            logger.warning(f"  [WARN] {name:14s}: {detail}")
        elif result == "INFO":
            logger.info(f"  [INFO] {name:14s}: {detail}")
        else:
            logger.error(f"  [FAIL] {name:14s}: {detail}")
    logger.info(f"  {'─' * 50}")
    logger.info(f"  总计 {total} 项 | 通过 {passed} | 警告 {warned} | 失败 {failed}")


def run_master_init(state: WorkflowStateManager) -> None:
    """
    初始化第一个 Master 节点。

    Args:
        state: 工作流状态管理器实例
    """
    # 前置校验：Stage 3 必须已通过
    state.require_stage_success("stage3_kube_components")

    logger.info("=" * 50)
    logger.info("Stage 4: 开始 Master 节点集群初始化")
    logger.info("=" * 50)

    # 加载配置
    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    cluster_info = YAMLHelper.load(os.path.join(CONFIG_DIR, "cluster_info.yaml"))

    masters = node_list.get("node_list", {}).get("masters", [])
    if not masters:
        raise MasterInitError("none", "未找到 Master 节点定义")

    master = masters[0]
    hostname = master["hostname"]
    ip = master["ip"]
    ssh_cfg = master.get("ssh", {})

    net = cluster_info.get("cluster_info", {}).get("networking", {})
    pod_cidr = net.get("pod_cidr", "10.244.0.0/16")
    service_cidr = net.get("service_cidr", "10.96.0.0/12")
    svc_node_port = net.get("service_node_port_range", "30000-32767")
    # 从配置文件读取版本作为 fallback，不再硬编码
    _ver_cfg = YAMLHelper.load(os.path.join(CONFIG_DIR, "software_version.yaml"))
    _cfg_default_ver = _ver_cfg.get("software_version", {}).get("kubernetes", {}).get("default", "1.32.13")
    k8s_version = state.get_global("k8s_version", _cfg_default_ver)
    kube_proxy_mode = cluster_info.get("cluster_info", {}).get("kube_proxy_mode", "iptables")
    # 镜像仓库：可从 cluster_info.yaml 配置，默认 registry.k8s.io
    image_repo = cluster_info.get("cluster_info", {}).get("container_runtime", {}).get(
        "image_repository", "registry.k8s.io"
    )

    # control_plane_endpoint：用 IP 而非 DNS 名（避免 DNS 不可用）
    cp_endpoint = f"{ip}:6443"

    ssh = SSHClient(
        host=ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
        password=ssh_cfg.get("password"),
        key_file=ssh_cfg.get("key_file"),
    )

    try:
        ssh.connect()

        # 幂等检查：已初始化且集群正常则跳过
        if _is_master_initialized(ssh):
            # 确保 join token 仍然可用
            _, join_cmd, _ = ssh.exec_command(
                "kubeadm token create --print-join-command 2>/dev/null || "
                "echo 'TOKEN_FAILED'",
                sudo=False, timeout=10
            )
            if "TOKEN_FAILED" not in join_cmd:
                state.set_global("join_command", join_cmd.strip())
                state.set_global("master_ip", ip)
                state.set_global("master_hostname", hostname)
                os.makedirs(TEMP_CACHE_DIR, exist_ok=True)
                with open(os.path.join(TEMP_CACHE_DIR, "join_command.sh"), "w") as f:
                    f.write(join_cmd.strip())
            _verify_master(ssh, hostname, k8s_version)
            logger.info(f"[{hostname}] Master 节点已初始化（幂等跳过）✓")
            return

        logger.info(f"[{hostname}] 开始 Master 节点初始化...")

        # 0. 检测并清理各种半残状态
        _cleanup_partial_init(ssh, hostname)

        # 1. 生成 kubeadm init 配置文件
        cert_sans = [ip, hostname]
        kubeadm_config = (
            "apiVersion: kubeadm.k8s.io/v1beta4\n"
            "kind: InitConfiguration\n"
            "localAPIEndpoint:\n"
            f"  advertiseAddress: {ip}\n"
            f"  bindPort: 6443\n"
            "nodeRegistration:\n"
            "  criSocket: unix:///var/run/containerd/containerd.sock\n"
            f"  name: {hostname}\n"
            "---\n"
            "apiVersion: kubeadm.k8s.io/v1beta4\n"
            "kind: ClusterConfiguration\n"
            f"kubernetesVersion: v{k8s_version}\n"
            f'imageRepository: "{image_repo}"\n'
            f'controlPlaneEndpoint: "{cp_endpoint}"\n'
            "networking:\n"
            f'  podSubnet: "{pod_cidr}"\n'
            f'  serviceSubnet: "{service_cidr}"\n'
            "  dnsDomain: cluster.local\n"
            "timeouts:\n"
            "  controlPlaneComponentHealthCheck: 10m0s\n"
            "  kubeletHealthCheck: 10m0s\n"
            "  etcdHealthCheck: 10m0s\n"
            "apiServer:\n"
            "  certSANs:\n"
            + "\n".join([f'    - "{s}"' for s in cert_sans]) + "\n"
            "---\n"
            "apiVersion: kubelet.config.k8s.io/v1beta1\n"
            "kind: KubeletConfiguration\n"
            "cgroupDriver: systemd\n"
            "---\n"
            "apiVersion: kubeproxy.config.k8s.io/v1alpha1\n"
            "kind: KubeProxyConfiguration\n"
            f"mode: {kube_proxy_mode}\n"
            "ipvs:\n"
            "  scheduler: rr\n"
        )

        ssh.exec_command(
            f"cat > /tmp/kubeadm-init.yaml << 'K8S_EOF'\n{kubeadm_config}\nK8S_EOF",
            sudo=False
        )
        logger.info(f"[{hostname}] kubeadm 配置文件已生成")

        # 2. 加载/拉取镜像
        #    策略: ① containerd 已有 → 跳过
        #          ② 阿里云/DaoCloud 直拉 → re-tag 官方（快，Master 国内网络）
        #          ③ 本地 tar 上传导入（慢，兜底）
        #          ④ kubeadm init 自身兜底
        logger.info(f"[{hostname}] 📥 准备 K8s 组件镜像...")
        _, img_list, _ = ssh.exec_command(
            "kubeadm config images list --config=/tmp/kubeadm-init.yaml 2>/dev/null",
            sudo=False
        )
        images = [l.strip() for l in img_list.split("\n") if l.strip()]
        # 确保 containerd 实际使用的 sandbox 镜像版本在预拉列表中
        # stage2 和 kubeadm init 都会写 containerd 配置，格式不同但版本号一致
        _, sandbox_ver, _ = ssh.exec_command(
            "grep -oE 'registry\\.k8s\\.io/pause:[0-9.]+' "
            "/etc/containerd/config.toml 2>/dev/null | head -1 || true",
            timeout=5
        )
        sandbox_ver = sandbox_ver.strip()
        if sandbox_ver and sandbox_ver not in images:
            images.append(sandbox_ver)
            logger.info(f"[{hostname}]   追加 containerd sandbox 镜像: {sandbox_ver}")
        logger.info(f"[{hostname}]   共 {len(images)} 个镜像")

        os.makedirs(IMAGES_DIR, exist_ok=True)
        ssh.exec_command_ok("mkdir -p /tmp/k8s-images", sudo=False)

        # 国内镜像源（按顺序尝试 + 自动扁平化路径）
        MIRROR_CANDIDATES = [
            "registry.cn-hangzhou.aliyuncs.com/google_containers",
            "docker.m.daocloud.io/k8s.gcr.io",
        ]

        # 一次性获取 containerd 已有镜像列表
        _, existing_raw, _ = ssh.exec_command(
            "ctr -n k8s.io image ls -q 2>/dev/null || true",
            sudo=False, timeout=10
        )
        existing_images = set(l.strip() for l in existing_raw.split("\n") if l.strip())

        for i, image in enumerate(images, 1):
            img_name = image.split("/")[-1].replace(":", "_")
            local_tar = os.path.join(IMAGES_DIR, f"{img_name}.tar")
            import_ok = False

            # ---- 检查 containerd 是否已有 ----
            if image in existing_images:
                logger.info(f"[{hostname}]   [{i}/{len(images)}] ✅ {img_name} 已存在，跳过")
                if not os.path.exists(local_tar):
                    logger.info(f"[{hostname}]   💾 回写本地缓存 {img_name}.tar ...")
                    ssh.exec_command(
                        f"ctr -n k8s.io image export /tmp/k8s-images/{img_name}.tar {image} 2>/dev/null",
                        sudo=False, timeout=30
                    )
                    try:
                        # 校验 tar 完整性：tar tf 成功才算有效
                        _, valid, _ = ssh.exec_command(
                            f"tar tf /tmp/k8s-images/{img_name}.tar >/dev/null 2>&1 && echo VALID || echo BROKEN",
                            timeout=10
                        )
                        if valid.strip() == "VALID":
                            ssh.download_file(f"/tmp/k8s-images/{img_name}.tar", local_tar)
                        else:
                            logger.debug(f"[{hostname}]   丢弃损坏缓存 {img_name}.tar")
                    except Exception:
                        pass
                continue

            # ---- 策略 A: 本地 tar 上传导入（优先，无网络依赖） ----
            if not import_ok and os.path.exists(local_tar):
                logger.info(f"[{hostname}]   [{i}/{len(images)}] 📦 本地上传 {img_name}...")
                ssh.upload_file(local_tar, f"/tmp/k8s-images/{img_name}.tar")
                exit_code, _, import_err = ssh.exec_command(
                    f"ctr -n k8s.io image import /tmp/k8s-images/{img_name}.tar 2>&1",
                    sudo=False, timeout=120
                )
                if exit_code == 0:
                    _, check, _ = ssh.exec_command(
                        f"ctr -n k8s.io image ls -q 2>/dev/null | grep -qF '{image}' && echo YES || echo NO",
                        sudo=False, timeout=10
                    )
                    if check.strip() == "YES":
                        import_ok = True
                        logger.info(f"[{hostname}]   ✅ {img_name} 本地加载完成")

            # ---- 策略 B: 远程直拉（国内镜像 → re-tag 官方） ----
            if not import_ok:
                logger.info(f"[{hostname}]   [{i}/{len(images)}] 🌐 拉取 {img_name}...")
                pulled_from_mirror = False
                for mirror in MIRROR_CANDIDATES:
                    # 构造候选 URL: 标准替换 + 扁平化（针对 coredns/coredns）
                    tag = image.split(":")[-1]
                    flat_name = image.split("/")[-1].split(":")[0]
                    candidates = [image.replace("registry.k8s.io", mirror)]
                    if "/" in image.replace("registry.k8s.io/", "").split(":")[0]:
                        candidates.append(f"{mirror}/{flat_name}:{tag}")
                    # 去重
                    candidates = list(dict.fromkeys(candidates))

                    for candidate in candidates:
                        exit_code, pull_out, _ = ssh.exec_command(
                            f"ctr -n k8s.io image pull {candidate} 2>&1 || echo PULL_FAILED",
                            sudo=False, timeout=180
                        )
                        if exit_code == 0 and "PULL_FAILED" not in pull_out:
                            import_ok = True
                            pulled_from_mirror = True
                            if candidate != image:
                                ssh.exec_command_ok(
                                    f"ctr -n k8s.io image tag {candidate} {image} && "
                                    f"ctr -n k8s.io image remove {candidate}",
                                    sudo=False, timeout=30
                                )
                            logger.info(f"[{hostname}]   ✅ {img_name} 远程拉取完成 (via {mirror.split('/')[0]})")
                            break
                    if pulled_from_mirror:
                        break

            # ---- 缓存回写 ----
            if import_ok and not os.path.exists(local_tar):
                logger.info(f"[{hostname}]   💾 回写缓存 → {img_name}.tar")
                ssh.exec_command(
                    f"ctr -n k8s.io image export /tmp/k8s-images/{img_name}.tar {image} 2>/dev/null",
                    sudo=False, timeout=30
                )
                try:
                    _, valid, _ = ssh.exec_command(
                        f"tar tf /tmp/k8s-images/{img_name}.tar >/dev/null 2>&1 && echo VALID || echo BROKEN",
                        timeout=10
                    )
                    if valid.strip() == "VALID":
                        ssh.download_file(f"/tmp/k8s-images/{img_name}.tar", local_tar)
                    else:
                        logger.debug(f"[{hostname}]   丢弃损坏缓存 {img_name}.tar")
                except Exception:
                    pass

            if not import_ok:
                logger.warning(f"[{hostname}]   ⚠️ {img_name} 全部方式失败，依赖 kubeadm init 兜底")

        ssh.exec_command("rm -rf /tmp/k8s-images", sudo=False)

        # 2.4 预拉取 Calico CNI 镜像（避免 stage6 部署时去 quay.io 直拉超时）
        #     containerd mirror 自动重定向 quay.io → DaoCloud 加速
        calico_ver = cluster_info.get("cluster_info", {}).get("cni", {}).get("calico", {}).get("version", "v3.29.1")
        calico_images = [
            f"quay.io/calico/cni:{calico_ver}",
            f"quay.io/calico/node:{calico_ver}",
            f"quay.io/calico/kube-controllers:{calico_ver}",
        ]
        # quay.io 镜像使用 DaoCloud 加速（阿里云 quayio 路径不可用）
        # DaoCloud 路径: docker.m.daocloud.io/calico/<image>:<tag>
        QUAY_MIRROR = "docker.m.daocloud.io"
        logger.info(f"[{hostname}] 📥 预拉取 Calico 镜像 ({calico_ver})...")
        for ci, calico_img in enumerate(calico_images, 1):
            img_name = calico_img.split("/")[-1].replace(":", "_")
            local_tar = os.path.join(IMAGES_DIR, f"{img_name}.tar")
            # 检查 containerd 是否已有
            if calico_img in existing_images:
                logger.info(f"[{hostname}]   [{ci}/{len(calico_images)}] ✅ {img_name} 已存在")
                continue
            # 本地 tar 优先
            pulled = False
            if os.path.exists(local_tar):
                logger.info(f"[{hostname}]   [{ci}/{len(calico_images)}] 📦 本地上传 {img_name}...")
                ssh.upload_file(local_tar, f"/tmp/k8s-images/{img_name}.tar")
                ec, _, _ = ssh.exec_command(
                    f"ctr -n k8s.io image import /tmp/k8s-images/{img_name}.tar 2>&1",
                    sudo=False, timeout=120
                )
                if ec == 0:
                    pulled = True
                    logger.info(f"[{hostname}]   ✅ {img_name} 本地加载完成")
            # 从 DaoCloud 镜像拉取
            if not pulled:
                mirror_img = calico_img.replace("quay.io", QUAY_MIRROR)
                logger.info(f"[{hostname}]   [{ci}/{len(calico_images)}] 🌐 拉取 {img_name}...")
                ec, po, _ = ssh.exec_command(
                    f"ctr -n k8s.io image pull {mirror_img} 2>&1 || echo PULL_FAILED",
                    sudo=False, timeout=300
                )
                if ec == 0 and "PULL_FAILED" not in po:
                    ssh.exec_command_ok(
                        f"ctr -n k8s.io image tag {mirror_img} {calico_img} && "
                        f"ctr -n k8s.io image remove {mirror_img}",
                        sudo=False, timeout=30
                    )
                    pulled = True
                    logger.info(f"[{hostname}]   ✅ {img_name} 远程拉取完成")
            if not pulled:
                logger.warning(f"[{hostname}]   ⚠️ {img_name} 预拉取失败，依赖 stage6 兜底")
        # 清理临时文件
        ssh.exec_command("rm -f /tmp/k8s-images/node_*.tar /tmp/k8s-images/cni_*.tar /tmp/k8s-images/kube-controllers_*.tar", sudo=False)
        _, existing_raw2, _ = ssh.exec_command(
            "ctr -n k8s.io image ls -q 2>/dev/null || true",
            sudo=False, timeout=10
        )
        existing_images = set(l.strip() for l in existing_raw2.split("\n") if l.strip())

        # 2.5 沙箱镜像保护：无论预拉取结果如何，确保 containerd sandbox 镜像存在
        #     kubeadm init 会改写 containerd 配置中的 sandbox_image 版本，
        #     如果该镜像不在 containerd 中，kubelet 会直接去 Google 拉 → 国内超时
        _, sandbox_needed, _ = ssh.exec_command(
            "grep -oE 'registry\\.k8s\\.io/pause:[0-9.]+' "
            "/etc/containerd/config.toml 2>/dev/null | head -1 || true",
            timeout=5
        )
        sandbox_needed = sandbox_needed.strip()
        if sandbox_needed:
            _, has_sandbox, _ = ssh.exec_command(
                f"ctr -n k8s.io image ls -q 2>/dev/null | grep -qF '{sandbox_needed}' && echo YES || echo NO",
                timeout=5
            )
            if has_sandbox.strip() != "YES":
                sandbox_tar_name = sandbox_needed.split("/")[-1].replace(":", "_") + ".tar"
                sandbox_local = os.path.join(IMAGES_DIR, sandbox_tar_name)
                if os.path.exists(sandbox_local):
                    logger.info(f"[{hostname}] 🔧 强制导入 sandbox 镜像: {sandbox_tar_name}")
                    ssh.upload_file(sandbox_local, f"/tmp/{sandbox_tar_name}")
                    ssh.exec_command(
                        f"ctr -n k8s.io image import /tmp/{sandbox_tar_name} 2>&1 || true",
                        sudo=False, timeout=30
                    )
                    ssh.exec_command(f"rm -f /tmp/{sandbox_tar_name}")
                else:
                    logger.warning(f"[{hostname}] ⚠️ sandbox 镜像 {sandbox_needed} 不在 containerd 中，"
                                   f"且本地 {sandbox_tar_name} 不存在，将尝试远程拉取")
                    # 最后兜底：从阿里云拉取
                    ver = sandbox_needed.split(":")[-1]
                    ssh.exec_command(
                        f"ctr -n k8s.io image pull registry.cn-hangzhou.aliyuncs.com/google_containers/pause:{ver} 2>&1 && "
                        f"ctr -n k8s.io image tag registry.cn-hangzhou.aliyuncs.com/google_containers/pause:{ver} {sandbox_needed} 2>&1 && "
                        f"ctr -n k8s.io image remove registry.cn-hangzhou.aliyuncs.com/google_containers/pause:{ver} 2>&1 || true",
                        sudo=False, timeout=60
                    )

        # 2.6 预检：确认 kubelet 能启动并与 containerd 通信
        #    如果 kubelet 无法启动（内核模块缺失/cgroup 不匹配/socket 不通），
        #    立即失败并给出明确诊断，而非等待 kubeadm init 超时 15 分钟
        #    注意: "activating" 是正常状态，表示 kubelet 已启动只是在等 API Server
        logger.info(f"[{hostname}] 🔍 预检 kubelet 启动能力...")
        ssh.exec_command("systemctl start kubelet 2>&1 || true", sudo=False, timeout=30)
        time.sleep(5)
        # 注意：systemctl is-active 对 "activating" 返回非零退出码，
        # 但不能用 || echo FALLBACK 否则会污染输出导致字符串匹配失败
        _, kubelet_status, _ = ssh.exec_command(
            "systemctl is-active kubelet 2>/dev/null; true",
            timeout=5
        )
        kubelet_status = kubelet_status.strip()
        logger.info(f"[{hostname}]   kubelet 启动测试: {kubelet_status}")

        # kubelet 启动后可能处于 active 或 activating（等待 API Server，正常）
        is_kubelet_ok = "active" in kubelet_status or "activating" in kubelet_status
        if not is_kubelet_ok:
            # 收集诊断信息
            _, kubelet_log, _ = ssh.exec_command(
                "journalctl -u kubelet --no-pager -n 30 2>/dev/null || echo NO_LOG",
                timeout=10
            )
            _, cri_check, _ = ssh.exec_command(
                "crictl --runtime-endpoint=unix:///var/run/containerd/containerd.sock "
                "info 2>&1 | head -5 || echo CRI_FAILED",
                timeout=10
            )
            # 额外检查内核模块
            _, mod_br, _ = ssh.exec_command(
                "lsmod | grep -E '^br_netfilter|^overlay|^ip_vs' | awk '{print $1}' | tr '\\n' ' ' || echo NONE",
                timeout=5
            )
            ssh.exec_command("systemctl stop kubelet 2>/dev/null || true", timeout=10)
            raise MasterInitError(
                hostname,
                f"kubelet 预检失败: 服务状态为 '{kubelet_status}'。"
                f"已加载关键内核模块: [{mod_br.strip()}]. "
                f"kubelet 日志: {kubelet_log[:300]}. "
                f"CRI 状态: {cri_check[:200]}"
            )

        # 停止 kubelet——kubeadm init 会正确启动它
        ssh.exec_command("systemctl stop kubelet 2>/dev/null || true", timeout=10)
        logger.info(f"[{hostname}]   kubelet 预检通过 ✓")

        # 3. kubeadm init（timeout 900s 覆盖 kubeadm 配置中 10m 健康检查超时）
        logger.info(f"[{hostname}] 🚀 执行 kubeadm init...")
        logger.info(f"[{hostname}]   (约 2-5 分钟，耐心等待，最长 15 分钟)")

        kubeadm_succeeded = False
        kubeadm_err_text = ""

        try:
            exit_code, stdout, stderr = ssh.exec_command(
                "kubeadm init --config=/tmp/kubeadm-init.yaml --upload-certs 2>&1",
                sudo=False, timeout=900,
            )
            for line in (stdout + stderr).split("\n"):
                line = line.strip()
                if not line:
                    continue
                if any(kw in line.lower() for kw in ["error", "fail", "fatal"]):
                    logger.error(f"[{hostname}]   │ {line[:150]}")
                elif any(kw in line.lower() for kw in ["warn"]):
                    logger.warning(f"[{hostname}]   │ {line[:150]}")
                else:
                    logger.info(f"[{hostname}]   │ {line[:150]}")

            kubeadm_err_text = (stderr + stdout)
            if exit_code == 0:
                kubeadm_succeeded = True
        except Exception as ssh_err:
            # SSH 超时或连接异常时，kubeadm 可能仍在后台运行
            kubeadm_err_text = str(ssh_err)
            logger.warning(f"[{hostname}] kubeadm init SSH 连接异常: {kubeadm_err_text[:200]}")

        # ---- 恢复路径：kubeadm 超时或报告 wait-control-plane ----
        if not kubeadm_succeeded:
            is_recoverable = (
                "wait-control-plane" in kubeadm_err_text
                or "context deadline" in kubeadm_err_text
                or "timeout" in kubeadm_err_text.lower()
                or "timed out" in kubeadm_err_text.lower()
            )

            # 检查 admin.conf 是否存在（恢复路径的前置条件）
            _, admin_exists, _ = ssh.exec_command(
                "test -f /etc/kubernetes/admin.conf && echo YES || echo NO",
                timeout=5
            )

            if is_recoverable and "YES" in admin_exists:
                # API Server 可能已由 kubelet 启动，只是 kubeadm 没等到
                logger.warning(f"[{hostname}] 控制平面启动较慢，等待 API Server ready...")
                api_ready = False
                for attempt in range(30):
                    time.sleep(10)
                    _, health, _ = ssh.exec_command(
                        "kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw /healthz 2>/dev/null || echo WAITING",
                        timeout=10
                    )
                    if "ok" in health:
                        logger.info(f"[{hostname}] ✅ API Server ready（等待 {(attempt+1)*10}s）")
                        api_ready = True
                        kubeadm_succeeded = True
                        break

                if api_ready:
                    # 修复 kubeconfig：将 DNS 主机名替换为 IP
                    ssh.exec_command(
                        f"grep -l 'k8s-api.testops.local' /etc/kubernetes/*.conf 2>/dev/null | "
                        f"xargs -r sed -i 's/k8s-api\\.testops\\.local/{ip}/g' 2>/dev/null || true",
                        timeout=10
                    )
                    # 等待 kubelet 重新注册节点
                    for i in range(30):
                        _, node_out, _ = ssh.exec_command(
                            "kubectl --kubeconfig=/etc/kubernetes/admin.conf get node --no-headers 2>/dev/null | grep -q Ready && echo YES || echo NO",
                            timeout=10
                        )
                        if node_out.strip() == "YES":
                            logger.info(f"[{hostname}] 节点已注册且 Ready")
                            break
                        time.sleep(5)
            elif is_recoverable and "NO" in admin_exists:
                # kubeadm 未完成到创建 admin.conf → 不可恢复
                err_summary = kubeadm_err_text[-500:]
                raise MasterInitError(
                    hostname,
                    f"kubeadm init 超时且未生成 admin.conf（控制平面未启动，"
                    f"请检查 kubelet/containerd/内核模块状态）: {err_summary}"
                )
            elif not is_recoverable:
                err_summary = kubeadm_err_text[-500:]
                raise MasterInitError(hostname, f"kubeadm init 失败: {err_summary}")

            if not kubeadm_succeeded:
                err_summary = kubeadm_err_text[-500:]
                raise MasterInitError(
                    hostname,
                    f"API Server 在 5 分钟轮询内未就绪。"
                    f"请执行 'journalctl -xeu kubelet' 和 "
                    f"'crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock ps -a' 排查。"
                    f"错误摘要: {err_summary}"
                )

        # 4. 修复 kubeconfig（将 DNS 主机名替换为 IP）+ 配置 kubectl
        ssh.exec_command(
            f"grep -l 'k8s-api.testops.local' /etc/kubernetes/*.conf 2>/dev/null | "
            f"xargs -r sed -i 's/k8s-api\\.testops\\.local/{ip}/g' 2>/dev/null || true",
            timeout=10
        )
        ssh.exec_command_ok(
            "mkdir -p $HOME/.kube && "
            "cp /etc/kubernetes/admin.conf $HOME/.kube/config && "
            "chown $(id -u):$(id -g) $HOME/.kube/config",
            sudo=False
        )
        logger.info(f"[{hostname}] kubectl 已配置")

        # 5. 生成并保存 join token
        _, join_cmd, _ = ssh.exec_command(
            "kubeadm token create --print-join-command", sudo=False
        )
        join_cmd = join_cmd.strip()
        logger.info(f"[{hostname}] Join token 已生成")

        os.makedirs(TEMP_CACHE_DIR, exist_ok=True)
        cache_file = os.path.join(TEMP_CACHE_DIR, "join_command.sh")
        with open(cache_file, "w") as f:
            f.write(join_cmd)

        state.set_global("join_command", join_cmd)
        state.set_global("master_ip", ip)
        state.set_global("master_hostname", hostname)

        # 6. 移除 Master 污点（允许调度 Pod）
        taints = master.get("taints", [])
        if not taints:
            ssh.exec_command(
                "kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes "
                "--all node-role.kubernetes.io/control-plane- 2>/dev/null || true",
                timeout=10
            )
            logger.info(f"[{hostname}] Master 污点已移除")

        # 7. 安装后扫描
        _verify_master(ssh, hostname, k8s_version)
        logger.info(f"[{hostname}] Master 节点初始化完成 ✓")

    except MasterInitError:
        raise
    except Exception as e:
        raise MasterInitError(hostname, str(e))
    finally:
        ssh.close()


def rollback_master_init(state: WorkflowStateManager) -> None:
    """
    回滚 Stage 4：彻底清除 Master 节点上的集群初始化痕迹。

    清理清单:
    1. kubeadm reset --force
    2. 停止 kubelet
    3. 删除 K8s 组件镜像 (registry.k8s.io/*)
    4. 删除配置文件和证书目录
    5. 删除数据目录 (/var/lib/kubelet, /var/lib/etcd)
    6. 清理 iptables 规则
    7. 清理 CNI 网络接口和配置
    8. 清理本地 join token 缓存
    """
    logger.info("=" * 50)
    logger.info("Stage 4 Rollback: 回滚 Master 初始化")
    logger.info("=" * 50)

    master_ip = state.get_global("master_ip")
    node_list = None
    if not master_ip:
        # 回退：从配置文件读取 Master IP（之前 init 未成功完成时 state 中无记录）
        logger.info("state 中无 master_ip，从 node_list.yaml 读取...")
        node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
        masters = node_list.get("node_list", {}).get("masters", [])
        if masters:
            master_ip = masters[0].get("ip")
    if not master_ip:
        logger.warning("未找到 Master 节点 IP（state 和配置文件均无），跳过回滚")
        return

    # 如果还没加载过 node_list，现在加载
    if node_list is None:
        node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    masters = node_list.get("node_list", {}).get("masters", [])
    if not masters:
        logger.warning("未找到 Master 节点定义")
        return

    master = masters[0]
    hostname = master["hostname"]
    ssh_cfg = master.get("ssh", {})

    ssh = SSHClient(
        host=master_ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
        password=ssh_cfg.get("password"),
        key_file=ssh_cfg.get("key_file"),
    )

    try:
        ssh.connect()
        logger.info(f"[{hostname}] 开始回滚 Master 初始化...")

        # 一条命令清干净（root 直执行，不用 sudo）
        cleanup_cmd = (
            # 1. 停止 kubelet + kill 进程（释放端口）
            "systemctl stop kubelet 2>/dev/null || true; "
            "systemctl disable kubelet 2>/dev/null || true; "
            "pkill -9 kubelet 2>/dev/null || true; "
            "sleep 1; "
            # 2. kubeadm reset（删容器 + 部分目录）
            "kubeadm reset --force --cri-socket=unix:///var/run/containerd/containerd.sock 2>&1 || true; "
            # 3. 删所有 K8s 镜像
            "ctr -n k8s.io image ls -q 2>/dev/null | xargs -r -n1 ctr -n k8s.io image remove 2>/dev/null || true; "
            # 4. 删文件/目录
            "rm -rf /root/.kube/ /tmp/kubeadm-init.yaml /tmp/k8s-images/ "
            "/etc/kubernetes/ /etc/cni/net.d/ /var/lib/kubelet/ /var/lib/etcd/ /var/lib/cni/ 2>/dev/null || true; "
            # 5. 清理 iptables
            "iptables -F 2>/dev/null || true; iptables -t nat -F 2>/dev/null || true; "
            "iptables -t mangle -F 2>/dev/null || true; iptables -X 2>/dev/null || true; "
            # 6. 清理网桥
            "ip link delete cni0 2>/dev/null || true; "
            "ip link delete flannel.1 2>/dev/null || true; "
            "ip link delete kube-ipvs0 2>/dev/null || true; "
            # 7. 重载 systemd
            "systemctl daemon-reload 2>/dev/null || true"
        )
        ssh.exec_command(cleanup_cmd, sudo=False, timeout=120)
        logger.info(f"[{hostname}] Master 回滚完成")

    except Exception as e:
        logger.warning(f"[{hostname}] 回滚异常（可忽略）: {e}")
    finally:
        ssh.close()

    # 清理本地缓存
    cache_file = os.path.join(TEMP_CACHE_DIR, "join_command.sh")
    if os.path.exists(cache_file):
        os.remove(cache_file)

    state.set_global("master_ip", None)
    state.set_global("join_command", None)
    state.set_global("master_hostname", None)
    logger.info("Master 回滚全部完成 ✓")
