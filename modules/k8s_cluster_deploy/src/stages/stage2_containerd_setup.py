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


def _setup_containerd_on_node(node: dict, version: str) -> None:
    """在单个节点上安装配置 containerd。"""
    hostname = node["hostname"]
    ip = node["ip"]
    ssh_cfg = node.get("ssh", {})

    ssh = SSHClient(
        host=ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
    )

    try:
        ssh.connect()
        logger.info(f"[{hostname}] 开始安装 containerd v{version}...")

        # 1. 安装 containerd
        install_cmd = (
            "yum install -y yum-utils && "
            "yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo && "
            f"yum install -y containerd.io-{version} 2>/dev/null || "
            f"yum install -y containerd.io"
        )
        ssh.exec_command_ok(install_cmd, sudo=True, timeout=300)
        logger.info(f"[{hostname}] containerd 已安装")

        # 2. 生成默认配置
        ssh.exec_command_ok("mkdir -p /etc/containerd", sudo=True)
        ssh.exec_command_ok(
            "containerd config default > /etc/containerd/config.toml",
            sudo=True
        )
        logger.info(f"[{hostname}] containerd 配置已生成")

        # 3. 配置 cgroup 驱动为 systemd
        ssh.exec_command_ok(
            "sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "
            "/etc/containerd/config.toml",
            sudo=True
        )
        logger.info(f"[{hostname}] Cgroup 驱动 → systemd")

        # 4. 配置镜像加速（从全局配置读取）
        mirror_config = YAMLHelper.load(
            os.path.join(GLOBAL_CONFIG_DIR, "mirror_repo.yaml"),
            raise_on_missing=False
        )
        if mirror_config:
            registry = mirror_config.get("mirror_repo", {}).get("container_registry", {})
            fallback = registry.get("fallback", "")
            if fallback:
                # 在 config.toml 中添加 mirror 配置
                mirror_section = (
                    f'\n[plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]\n'
                    f'  endpoint = ["https://{fallback}"]'
                )
                ssh.exec_command(
                    f"echo '{mirror_section}' >> /etc/containerd/config.toml",
                    sudo=True
                )
                logger.info(f"[{hostname}] 镜像加速已配置: {fallback}")

        # 5. 启动服务
        ssh.exec_command_ok("systemctl daemon-reload", sudo=True)
        ssh.exec_command_ok("systemctl enable containerd --now", sudo=True)

        # 6. 验证服务
        exit_code, status, _ = ssh.exec_command(
            "systemctl is-active containerd", sudo=True
        )
        if "active" not in status:
            raise ContainerdSetupError(
                hostname, f"containerd 服务未正常启动: {status.strip()}"
            )

        logger.info(f"[{hostname}] containerd 安装完成 ✓")

    except ContainerdSetupError:
        raise
    except Exception as e:
        raise ContainerdSetupError(hostname, str(e))
    finally:
        ssh.close()


def run_containerd_setup(state: WorkflowStateManager) -> None:
    """
    在全部节点上安装配置 containerd。

    Args:
        state: 工作流状态管理器实例
    """
    logger.info("=" * 50)
    logger.info("Stage 2: 开始容器运行时安装配置")
    logger.info("=" * 50)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    version_config = YAMLHelper.load(os.path.join(CONFIG_DIR, "software_version.yaml"))
    containerd_version = version_config.get("software_version", {}).get(
        "containerd", {}
    ).get("default", "1.7.13")

    all_nodes = _get_all_nodes(node_list)

    for node in all_nodes:
        _setup_containerd_on_node(node, containerd_version)

    logger.info(f"容器运行时安装完成: {len(all_nodes)} 个节点")
    state.set_global("containerd_setup_completed", True)
    state.set_global("containerd_version", containerd_version)
