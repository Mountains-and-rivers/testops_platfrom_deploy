"""
Stage 3: kubeadm / kubectl / kubelet 安装

在所有节点上：
- 添加 Kubernetes YUM 仓库（pkgs.k8s.io 官方源）
- 安装指定版本的 kubeadm、kubectl、kubelet
- 配置 kubelet（cgroup 驱动 + containerd socket）
- 启用 kubelet 服务（等待 kubeadm init 接管）
"""

import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.workflow_state import WorkflowStateManager
from common.yaml_helper import YAMLHelper
from common.ssh_client import SSHClient
from src.workflow.workflow_exception import KubeComponentInstallError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "config")
YUM_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "yum")
# RPM 本地缓存与 images/ 放一起（版本配套）
RPM_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "images")

# K8s RPM 仓库模板（兜底：阿里云镜像加速）
K8S_REPO_TEMPLATE = (
    "[kubernetes]\n"
    "name=Kubernetes\n"
    "baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-$basearch/\n"
    "enabled=1\n"
    "gpgcheck=0\n"
    "gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg\n"
    "       https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg\n"
)


def _get_all_nodes(node_list: dict) -> list:
    """提取所有节点。"""
    nodes = []
    for master in node_list.get("node_list", {}).get("masters", []):
        nodes.append(master)
    for worker in node_list.get("node_list", {}).get("workers", []):
        nodes.append(worker)
    return nodes


def _get_minor_version(k8s_version: str) -> str:
    """从完整版本号提取 minor 版本（如 1.36.3 → 1.36）。"""
    parts = k8s_version.split(".")
    if len(parts) >= 2:
        return f"{parts[0]}.{parts[1]}"
    return k8s_version


def _install_kube_on_node(node: dict, k8s_minor: str) -> str:
    """在单个节点上安装 Kubernetes 组件，返回实际安装的版本号。"""
    hostname = node["hostname"]
    ip = node["ip"]
    ssh_cfg = node.get("ssh", {})

    ssh = SSHClient(
        host=ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
        password=ssh_cfg.get("password"),
        key_file=ssh_cfg.get("key_file"),
    )

    try:
        ssh.connect()
        # 0. 检查本地 RPM 缓存（与 images/*.tar 版本配套，优先使用）
        local_rpms = []
        if os.path.isdir(RPM_DIR):
            local_rpms = sorted([f for f in os.listdir(RPM_DIR) if f.endswith('.rpm')])
        if local_rpms:
            logger.info(f"[{hostname}] 📦 本地 RPM 安装 ({len(local_rpms)} 个)...")
            ssh.exec_command("mkdir -p /tmp/k8s_rpms", sudo=False)
            for rpm_file in local_rpms:
                ssh.upload_file(os.path.join(RPM_DIR, rpm_file), f"/tmp/k8s_rpms/{rpm_file}")
            exit_code, stdout, stderr = ssh.exec_command(
                "rpm -Uvh --replacepkgs /tmp/k8s_rpms/*.rpm 2>&1",
                sudo=False, timeout=120
            )
            ssh.exec_command("rm -rf /tmp/k8s_rpms", sudo=False)
            if exit_code != 0:
                raise KubeComponentInstallError(
                    hostname, "kubeadm/kubectl/kubelet",
                    f"本地 RPM 安装失败 (exit={exit_code}): {stderr[:300]}"
                )
        else:
            # 无本地 RPM，回退在线安装（智能获取仓库最新版本）
            ssh.exec_command(
                f"cat > /etc/yum.repos.d/kubernetes.repo << 'EOF'\n"
                f"[kubernetes]\n"
                f"name=Kubernetes\n"
                f"baseurl=https://pkgs.k8s.io/core:/stable:/v{k8s_minor}/rpm/\n"
                f"enabled=1\n"
                f"gpgcheck=0\n"
                f"EOF",
                sudo=False
            )
            _, latest_ver, _ = ssh.exec_command(
                "yum --disablerepo=* --enablerepo=kubernetes list available kubeadm.x86_64 2>/dev/null | "
                "grep kubeadm | awk '{print $2}' | sort -V | tail -1 || true",
                sudo=False, timeout=30
            )
            latest_ver = latest_ver.strip()
            if not latest_ver:
                raise KubeComponentInstallError(hostname, "kubeadm/kubectl/kubelet",
                                                 "无法从仓库获取最新 kubeadm 版本，请检查 YUM 源")
            logger.info(f"[{hostname}] 仓库最新版本: {latest_ver}")
            exit_code, stdout, stderr = ssh.exec_command(
                "yum install -y kubeadm kubectl kubelet",
                sudo=False, timeout=300
            )
            if exit_code != 0:
                raise KubeComponentInstallError(
                    hostname, "kubeadm/kubectl/kubelet",
                    f"在线安装失败 (exit={exit_code}): {stderr[:300]}"
                )

        # 获取实际安装的版本
        _, version_out, _ = ssh.exec_command(
            "kubeadm version -o short 2>/dev/null || echo unknown",
            sudo=False
        )
        actual_version = version_out.strip()
        logger.info(f"[{hostname}] K8s 组件已安装: {actual_version}")

        # 3. 配置 kubelet（cgroup 驱动 + containerd socket）
        kubelet_config = (
            'KUBELET_EXTRA_ARGS="--cgroup-driver=systemd '
            '--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock"'
        )
        ssh.exec_command(
            f"echo '{kubelet_config}' > /etc/sysconfig/kubelet",
            sudo=False
        )
        logger.debug(f"[{hostname}] kubelet 配置已写入")

        # 4. 配置 crictl（kubeadm/kubelet 通过 crictl 与容器运行时通信）
        #    无此文件时部分 kubeadm 版本无法定位 CRI socket
        crictl_config = (
            "runtime-endpoint: unix:///var/run/containerd/containerd.sock\n"
            "image-endpoint: unix:///var/run/containerd/containerd.sock\n"
            "timeout: 10\n"
            "debug: false\n"
        )
        ssh.exec_command(
            f"cat > /etc/crictl.yaml << 'CRICTL_EOF'\n{crictl_config}\nCRICTL_EOF",
            sudo=False
        )
        logger.debug(f"[{hostname}] crictl.yaml 已配置")

        # 5. 启用 kubelet（不启动，等待 kubeadm init 接管）
        ssh.exec_command_ok("systemctl enable kubelet 2>/dev/null || true", sudo=False)

        # 6. 安装后扫描验证
        _verify_kube(ssh, hostname, actual_version)
        logger.info(f"[{hostname}] K8s 组件安装完成 ✓")

        return actual_version

    except KubeComponentInstallError:
        raise
    except Exception as e:
        raise KubeComponentInstallError(hostname, "kubeadm/kubectl/kubelet", str(e))
    finally:
        ssh.close()


def _verify_kube(ssh: SSHClient, hostname: str, expected_version: str) -> None:
    """安装后扫描验证 kubeadm/kubectl/kubelet 版本、二进制、配置。"""
    logger.info(f"[{hostname}] 🔍 安装后扫描验证...")
    checks = []
    # 去掉版本号可能带有的 v 前缀
    expected_ver = expected_version.lstrip("v")

    # 1. kubeadm — rpm 查询版本（最可靠）
    _, rpm_out, _ = ssh.exec_command(
        "rpm -q --queryformat '%{VERSION}' kubeadm 2>/dev/null || echo MISSING"
    )
    rpm_ver = rpm_out.strip()
    if rpm_ver and rpm_ver != "MISSING":
        status = "PASS" if rpm_ver == expected_ver else "WARN"
        checks.append(("kubeadm版本", status, f"{rpm_ver} (期望 {expected_ver})"))
    else:
        checks.append(("kubeadm版本", "FAIL", "未安装"))

    # 2. kubectl — rpm 查询
    _, rpm_out, _ = ssh.exec_command(
        "rpm -q --queryformat '%{VERSION}' kubectl 2>/dev/null || echo MISSING"
    )
    rpm_ver = rpm_out.strip()
    if rpm_ver and rpm_ver != "MISSING":
        status = "PASS" if rpm_ver == expected_ver else "WARN"
        checks.append(("kubectl版本", status, f"{rpm_ver} (期望 {expected_ver})"))
    else:
        checks.append(("kubectl版本", "FAIL", "未安装"))

    # 3. kubelet — rpm 查询
    _, rpm_out, _ = ssh.exec_command(
        "rpm -q --queryformat '%{VERSION}' kubelet 2>/dev/null || echo MISSING"
    )
    rpm_ver = rpm_out.strip()
    if rpm_ver and rpm_ver != "MISSING":
        status = "PASS" if rpm_ver == expected_ver else "WARN"
        checks.append(("kubelet版本", status, f"{rpm_ver} (期望 {expected_ver})"))
    else:
        checks.append(("kubelet版本", "FAIL", "未安装"))

    # 4. 二进制文件可执行
    binaries_ok = []
    for binary in ["kubeadm", "kubectl", "kubelet"]:
        _, path_out, _ = ssh.exec_command(f"command -v {binary} 2>/dev/null || echo MISSING")
        if "MISSING" not in path_out:
            binaries_ok.append(binary)
    if len(binaries_ok) == 3:
        checks.append(("二进制路径", "PASS", "kubeadm/kubectl/kubelet 均可执行"))
    else:
        missing = set(["kubeadm", "kubectl", "kubelet"]) - set(binaries_ok)
        checks.append(("二进制路径", "FAIL", f"缺失: {missing}"))

    # 5. kubelet 开机自启
    _, enabled, _ = ssh.exec_command("systemctl is-enabled kubelet 2>/dev/null || echo NONE")
    if "enabled" in enabled:
        checks.append(("kubelet自启", "PASS", "enabled"))
    else:
        checks.append(("kubelet自启", "FAIL", enabled.strip()))

    # 6. kubelet 配置文件
    _, cfg, _ = ssh.exec_command(
        "grep -c 'cgroup-driver=systemd' /etc/sysconfig/kubelet 2>/dev/null || echo 0"
    )
    if int((cfg.strip() or "0").splitlines()[0]) > 0:
        checks.append(("kubelet配置", "PASS", "cgroup=systemd + containerd socket"))
    else:
        checks.append(("kubelet配置", "FAIL", "配置缺失或错误"))

    # 7. K8s YUM repo 存在且 URL 正确（本地 RPM 安装时无此文件也正常）
    _, repo_url, _ = ssh.exec_command(
        "grep '^baseurl=' /etc/yum.repos.d/kubernetes.repo 2>/dev/null || echo MISSING"
    )
    if "MISSING" not in repo_url:
        minor = ".".join(expected_ver.split(".")[:2])
        if minor in repo_url:
            checks.append(("YUM仓库", "PASS", repo_url.strip()[:70]))
        else:
            checks.append(("YUM仓库", "WARN", f"版本不匹配: {repo_url.strip()[:60]}"))
    else:
        checks.append(("YUM仓库", "WARN", "缺失（本地 RPM 安装无需仓库）"))

    # 8. kubelet 服务状态（应 inactive，等待 kubeadm init）
    _, kls, _ = ssh.exec_command("systemctl is-active kubelet 2>/dev/null || echo inactive")
    kls = kls.strip()
    if kls == "inactive":
        checks.append(("kubelet状态", "PASS", "inactive（等待 kubeadm init）"))
    else:
        checks.append(("kubelet状态", "INFO", kls))

    # 汇总
    logger.info(f"  {'─' * 45}")
    passed = sum(1 for _, r, _ in checks if r == "PASS")
    failed = sum(1 for _, r, _ in checks if r == "FAIL")
    for name, result, detail in checks:
        icon = "✅" if result == "PASS" else ("⚠️" if result == "WARN" else ("ℹ️" if result == "INFO" else "❌"))
        logger.info(f"  {icon} {name:12s}: {detail}")
    logger.info(f"  {'─' * 45}")
    logger.info(f"  总计 {len(checks)} 项 | 通过 {passed} | 失败 {failed}")

    if failed > 0:
        raise KubeComponentInstallError(hostname, "安装后验证", f"{failed} 项未通过")


def run_kube_components(state: WorkflowStateManager) -> None:
    """
    在全部节点上安装 Kubernetes 组件。

    Args:
        state: 工作流状态管理器实例
    """
    # 前置校验：Stage 2 必须已通过
    state.require_stage_success("stage2_containerd_setup")

    logger.info("=" * 50)
    logger.info("Stage 3: 开始 K8s 组件安装")
    logger.info("=" * 50)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    version_config = YAMLHelper.load(os.path.join(CONFIG_DIR, "software_version.yaml"))
    k8s_full = version_config.get("software_version", {}).get(
        "kubernetes", {}
    ).get("default", "1.32")
    k8s_minor = _get_minor_version(k8s_full)

    all_nodes = _get_all_nodes(node_list)

    actual_version = k8s_full
    for node in all_nodes:
        actual_version = _install_kube_on_node(node, k8s_minor)

    logger.info(f"K8s 组件安装完成: {len(all_nodes)} 个节点, 版本 {actual_version}")
    state.set_global("kube_components_installed", True)
    state.set_global("k8s_version", actual_version.lstrip("v"))


def rollback_kube_components(state: WorkflowStateManager) -> None:
    """
    回滚 Stage 3：卸载所有节点上的 kubeadm/kubectl/kubelet。

    操作：
    - 停止并禁用 kubelet 服务
    - 卸载 K8s 组件包
    - 删除 YUM 仓库配置
    - 删除 kubelet 配置和数据目录
    """
    logger.info("=" * 50)
    logger.info("Stage 3 Rollback: 回滚 K8s 组件")
    logger.info("=" * 50)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    all_nodes = _get_all_nodes(node_list)

    for node in all_nodes:
        hostname = node["hostname"]
        ip = node["ip"]
        ssh_cfg = node.get("ssh", {})

        ssh = SSHClient(
            host=ip,
            username=ssh_cfg.get("username", "root"),
            port=ssh_cfg.get("port", 22),
            password=ssh_cfg.get("password"),
            key_file=ssh_cfg.get("key_file"),
        )

        try:
            ssh.connect()
            logger.info(f"[{hostname}] 开始卸载 K8s 组件...")

            # 停止 + 禁用
            ssh.exec_command("systemctl stop kubelet 2>/dev/null || true", sudo=False)
            ssh.exec_command("systemctl disable kubelet 2>/dev/null || true", sudo=False)
            # 卸载包
            ssh.exec_command(
                "yum remove -y kubeadm kubectl kubelet 2>/dev/null || true",
                sudo=False, timeout=120
            )
            # 删除仓库、配置、数据
            ssh.exec_command("rm -f /etc/yum.repos.d/kubernetes.repo", sudo=False)
            ssh.exec_command("rm -f /etc/sysconfig/kubelet", sudo=False)
            ssh.exec_command("rm -rf /var/lib/kubelet /etc/kubernetes", sudo=False)

            logger.info(f"[{hostname}] K8s 组件卸载完成 ✓")

        except Exception as e:
            logger.warning(f"[{hostname}] 回滚时出现错误（可忽略）: {e}")
        finally:
            ssh.close()

    logger.info("K8s 组件回滚完成")
    state.set_global("kube_components_installed", False)
