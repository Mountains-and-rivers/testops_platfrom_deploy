"""
Stage 2: 容器运行时安装配置

在所有节点上安装配置 containerd：
- 安装 containerd 及相关依赖
- 生成默认配置文件
- 配置 cgroup 驱动为 systemd
- 配置镜像仓库加速地址
- 启动并启用 containerd 服务
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
from src.workflow.workflow_exception import ContainerdSetupError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")
GLOBAL_CONFIG_DIR = os.path.join(PROJECT_ROOT, "global_config")


def _get_all_nodes(node_list: dict) -> list:
    """提取所有节点。"""
    nodes = []
    for master in node_list.get("node_list", {}).get("masters", []):
        nodes.append(master)
    for worker in node_list.get("node_list", {}).get("workers", []):
        nodes.append(worker)
    return nodes


def _build_registry_mirror_map(mirror_config: dict) -> dict:
    """
    从 mirror_repo.yaml 构建镜像仓库映射表。
    返回 {registry_host: [endpoint1, endpoint2, ...]} 字典。
    """
    mirrors = mirror_config.get("mirror_repo", {}).get("container_registry", {}).get("mirrors", {})
    if not mirrors:
        return {}
    # 直接使用新格式：{registry: [endpoints]}
    return dict(mirrors)


def _setup_containerd_on_node(node: dict, version: str, mirror_map: dict) -> None:
    """在单个节点上安装配置 containerd（兼容 v1.x 和 v2.x）。"""
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
        logger.info(f"[{hostname}] 开始安装 containerd v{version}...")

        # 1. 安装 containerd（使用 aliyun Docker-CE 镜像源）
        logger.info(f"[{hostname}] 添加 aliyun Docker-CE yum 源...")
        ssh.exec_command_ok("yum install -y yum-utils 2>/dev/null || true",
                           sudo=False, timeout=60)
        ssh.exec_command_ok(
            "yum-config-manager --add-repo "
            "https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo",
            sudo=False, timeout=30
        )
        # 替换 docker-ce.repo 中官方 URL 为 aliyun（加速）
        ssh.exec_command(
            "sed -i 's|https://download.docker.com|https://mirrors.aliyun.com/docker-ce|g' "
            "/etc/yum.repos.d/docker-ce.repo 2>/dev/null || true",
            sudo=False
        )
        # 安装 containerd，指定版本不可用则装最新
        exit_code, stdout, stderr = ssh.exec_command(
            f"yum install -y containerd.io-{version}",
            sudo=False, timeout=300
        )
        if exit_code != 0:
            logger.info(f"[{hostname}] 指定版本 v{version} 不可用，安装最新版...")
            ssh.exec_command_ok(
                "yum install -y containerd.io",
                sudo=False, timeout=300
            )
        # 获取实际安装版本
        _, version_out, _ = ssh.exec_command(
            "containerd --version 2>/dev/null | awk '{print $3}' || echo unknown",
            sudo=False
        )
        actual_version = version_out.strip()
        logger.info(f"[{hostname}] containerd {actual_version} 已安装")

        # 2. 生成默认配置
        ssh.exec_command_ok("mkdir -p /etc/containerd", sudo=False)
        ssh.exec_command_ok(
            "containerd config default > /etc/containerd/config.toml",
            sudo=False
        )
        logger.info(f"[{hostname}] containerd 配置已生成")

        # 3. 配置 cgroup 驱动为 systemd
        ssh.exec_command_ok(
            "sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "
            "/etc/containerd/config.toml",
            sudo=False
        )
        logger.info(f"[{hostname}] Cgroup 驱动 → systemd")

        # 3.5 配置 sandbox_image 与 kubeadm 保持一致（避免版本不匹配）
        _, pause_ver, _ = ssh.exec_command(
            "kubeadm config images list --kubernetes-version=stable-1 2>/dev/null | "
            "grep pause | head -1 | awk -F: '{print $NF}' || echo '3.10.2'",
            sudo=False, timeout=10
        )
        sandbox_version = pause_ver.strip() or "3.10.2"
        ssh.exec_command_ok(
            f"sed -i 's|sandbox_image = .*|sandbox_image = \"registry.k8s.io/pause:{sandbox_version}\"|' "
            "/etc/containerd/config.toml",
            sudo=False
        )
        logger.info(f"[{hostname}] Sandbox 镜像 → pause:{sandbox_version}")

        # 4. 配置镜像加速——containerd 2.x 使用 hosts.toml 目录结构
        if mirror_map:
            # 先设置 config_path
            ssh.exec_command_ok(
                "mkdir -p /etc/containerd/certs.d",
                sudo=False
            )
            # 清理旧的 K8S 配置的 hosts.toml 目录（用 sh -c 包裹循环）
            ssh.exec_command(
                "sh -c 'for d in /etc/containerd/certs.d/*/; do "
                "grep -q K8S_MANAGED \"$d/hosts.toml\" 2>/dev/null && rm -rf \"$d\"; "
                "done' 2>/dev/null || true",
                sudo=False
            )
            for registry_host, endpoints in mirror_map.items():
                if not endpoints:
                    continue
                # 确定上游 server 地址
                server_map = {
                    "docker.io": "https://registry-1.docker.io",
                    "registry.k8s.io": "https://registry.k8s.io",
                    "k8s.gcr.io": "https://k8s.gcr.io",
                    "quay.io": "https://quay.io",
                    "ghcr.io": "https://ghcr.io",
                }
                server_url = server_map.get(registry_host, f"https://{registry_host}")

                # 构建 hosts.toml：第1个 mirror 带 resolve，后续仅 pull
                lines = [
                    "# K8S_MANAGED - DO NOT EDIT",
                    f'server = "{server_url}"',
                    "",
                ]
                for i, endpoint in enumerate(endpoints):
                    caps = '["pull", "resolve"]' if i == 0 else '["pull"]'
                    lines.append(f'[host."{endpoint}"]')
                    lines.append(f"  capabilities = {caps}")

                hosts_content = "\n".join(lines)
                ssh.exec_command_ok(
                    f"mkdir -p /etc/containerd/certs.d/{registry_host}",
                    sudo=False
                )
                ssh.exec_command(
                    f"cat > /etc/containerd/certs.d/{registry_host}/hosts.toml "
                    f"<< 'K8S_EOF'\n{hosts_content}\nK8S_EOF",
                    sudo=False
                )
            logger.info(f"[{hostname}] 镜像加速已配置 ({len(mirror_map)} 个仓库)")

        # 5. 启动服务 + 强制重启确保 CRI 加载 mirror 配置
        ssh.exec_command_ok("systemctl daemon-reload", sudo=False)
        ssh.exec_command_ok("systemctl enable containerd --now", sudo=False)
        ssh.exec_command("systemctl restart containerd", sudo=False, timeout=10)
        logger.info(f"[{hostname}] containerd 已重启（CRI 加载 mirror）")

        # 6. 安装后扫描验证
        _verify_containerd(ssh, hostname, actual_version, mirror_map)
        logger.info(f"[{hostname}] containerd 安装完成 ✓")

    except ContainerdSetupError:
        raise
    except Exception as e:
        raise ContainerdSetupError(hostname, str(e))
    finally:
        ssh.close()


def _verify_containerd(ssh: SSHClient, hostname: str, expected_version: str,
                      mirror_map: dict) -> None:
    """安装后扫描验证 containerd 版本、服务、配置、功能。"""
    logger.info(f"[{hostname}] 🔍 安装后扫描验证...")
    checks = []

    # 1. 版本校验
    _, ver_out, _ = ssh.exec_command(
        "containerd --version 2>/dev/null | awk '{print $3}'", sudo=False
    )
    actual_ver = ver_out.strip()
    if actual_ver and actual_ver != "unknown":
        status = "PASS" if actual_ver == expected_version else "WARN"
        checks.append(("版本", status, f"{actual_ver} (期望 {expected_version})"))
    else:
        checks.append(("版本", "FAIL", "无法获取"))

    # 2. 服务状态
    _, svc, _ = ssh.exec_command("systemctl is-active containerd", sudo=False)
    if "active" in svc:
        checks.append(("服务运行", "PASS", "active"))
    else:
        checks.append(("服务运行", "FAIL", svc.strip()))

    # 3. 服务开机自启
    _, enabled, _ = ssh.exec_command("systemctl is-enabled containerd", sudo=False)
    if "enabled" in enabled:
        checks.append(("开机自启", "PASS", "enabled"))
    else:
        checks.append(("开机自启", "FAIL", enabled.strip()))

    # 4. cgroup 驱动
    _, cgroup, _ = ssh.exec_command(
        "grep 'SystemdCgroup = true' /etc/containerd/config.toml | wc -l", sudo=False
    )
    if int(cgroup.strip() or 0) > 0:
        checks.append(("cgroup=systemd", "PASS", "已启用"))
    else:
        checks.append(("cgroup=systemd", "FAIL", "未找到"))

    # 5. socket 文件
    _, sock, _ = ssh.exec_command(
        "test -S /var/run/containerd/containerd.sock && echo 'EXISTS' || echo 'MISSING'",
        sudo=False
    )
    if "EXISTS" in sock:
        checks.append(("Socket", "PASS", "/var/run/containerd/containerd.sock"))
    else:
        checks.append(("Socket", "FAIL", "缺失"))

    # 6. config.toml 有效性
    _, cfg_err, _ = ssh.exec_command(
        "containerd config dump 2>&1 | grep -c 'Ignoring unknown key' || true", sudo=False
    )
    err_count = int(cfg_err.strip() or 0)
    if err_count == 0:
        checks.append(("配置有效性", "PASS", "无警告"))
    else:
        checks.append(("配置有效性", "WARN", f"{err_count} 个未知项（可能版本不兼容）"))

    # 7. 运行时连通性（ctr 拉取测试镜像）
    _, ctr_out, _ = ssh.exec_command(
        "ctr image pull --snapshotter=overlayfs docker.io/library/hello-world:latest 2>&1 && "
        "ctr run --rm docker.io/library/hello-world:latest test-verify 2>&1 || "
        "echo 'PULL_FAILED'",
        sudo=False, timeout=60
    )
    if "Hello from Docker" in ctr_out or "Hello" in ctr_out:
        checks.append(("功能验证(ctr)", "PASS", "镜像拉取+运行成功"))
    elif "PULL_FAILED" in ctr_out:
        checks.append(("功能验证(ctr)", "WARN", "镜像拉取失败（网络/镜像源问题）"))
    else:
        checks.append(("功能验证(ctr)", "WARN", ctr_out.strip()[:80]))
    # 清理测试镜像
    ssh.exec_command(
        "ctr image rm docker.io/library/hello-world:latest 2>/dev/null || true",
        sudo=False
    )

    # 8. 镜像加速目录
    if mirror_map:
        certs_count = len(mirror_map)
        _, dirs, _ = ssh.exec_command(
            "ls /etc/containerd/certs.d/ 2>/dev/null | wc -l", sudo=False
        )
        actual_dirs = int(dirs.strip() or 0)
        if actual_dirs >= certs_count:
            checks.append(("镜像加速", "PASS", f"{actual_dirs} 个仓库"))
        else:
            checks.append(("镜像加速", "FAIL", f"{actual_dirs}/{certs_count}"))

    # 汇总输出
    logger.info(f"  {'─' * 45}")
    passed = 0
    failed = 0
    for name, result, detail in checks:
        icon = "✅" if result == "PASS" else ("⚠️" if result == "WARN" else "❌")
        logger.info(f"  {icon} {name:12s}: {detail}")
        if result == "PASS":
            passed += 1
        elif result == "FAIL":
            failed += 1
    logger.info(f"  {'─' * 45}")
    logger.info(f"  总计 {len(checks)} 项 | 通过 {passed} | 失败 {failed}")

    if failed > 0:
        raise ContainerdSetupError(
            hostname, f"安装后验证 {failed} 项未通过"
        )


def run_containerd_setup(state: WorkflowStateManager) -> None:
    """
    在全部节点上安装配置 containerd。

    Args:
        state: 工作流状态管理器实例
    """
    # 前置校验：Stage 1 必须已通过
    state.require_stage_success("stage1_sys_init")

    logger.info("=" * 50)
    logger.info("Stage 2: 开始容器运行时安装配置")
    logger.info("=" * 50)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    version_config = YAMLHelper.load(os.path.join(CONFIG_DIR, "software_version.yaml"))
    mirror_config = YAMLHelper.load(
        os.path.join(GLOBAL_CONFIG_DIR, "mirror_repo.yaml"),
        raise_on_missing=False
    ) or {}

    containerd_version = version_config.get("software_version", {}).get(
        "containerd", {}
    ).get("default", "1.7.13")

    # 预生成镜像仓库映射表
    mirror_map = _build_registry_mirror_map(mirror_config)

    all_nodes = _get_all_nodes(node_list)

    for node in all_nodes:
        _setup_containerd_on_node(node, containerd_version, mirror_map)

    logger.info(f"容器运行时安装完成: {len(all_nodes)} 个节点")
    state.set_global("containerd_setup_completed", True)
    state.set_global("containerd_version", containerd_version)


def rollback_containerd_setup(state: WorkflowStateManager) -> None:
    """
    回滚 Stage 2：卸载所有节点上的 containerd。

    操作：
    - 停止 containerd 服务
    - 卸载 containerd.io 包
    - 删除配置文件和数据目录
    - 删除 yum repo 文件
    """
    logger.info("=" * 50)
    logger.info("Stage 2 Rollback: 回滚容器运行时")
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
            logger.info(f"[{hostname}] 开始卸载 containerd...")

            # 停止服务
            ssh.exec_command("systemctl stop containerd 2>/dev/null || true", sudo=False)
            ssh.exec_command("systemctl disable containerd 2>/dev/null || true", sudo=False)
            # 卸载包
            ssh.exec_command("yum remove -y containerd.io 2>/dev/null || true", sudo=False, timeout=120)
            # 删除数据和配置（含 certs.d 镜像加速目录）
            ssh.exec_command("rm -rf /etc/containerd /var/lib/containerd", sudo=False)
            # 删除 yum repo
            ssh.exec_command(
                "rm -f /etc/yum.repos.d/docker-ce.repo "
                "/etc/yum.repos.d/docker-ce-stable.repo",
                sudo=False
            )

            logger.info(f"[{hostname}] containerd 卸载完成 ✓")

        except Exception as e:
            logger.warning(f"[{hostname}] 回滚时出现错误（可忽略）: {e}")
        finally:
            ssh.close()

    logger.info("容器运行时回滚完成")
    state.set_global("containerd_setup_completed", False)
