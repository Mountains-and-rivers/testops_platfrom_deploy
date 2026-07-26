"""
Stage 3: kubeadm / kubectl / kubelet 安装

在所有节点上：
- 添加 Kubernetes YUM/APT 仓库
- 安装指定版本的 kubeadm、kubectl、kubelet
- 配置 kubelet cgroup 驱动
- 启用 kubelet 服务（此时会处于等待状态，由 kubeadm init 接管）
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

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")


def _get_all_nodes(node_list: dict) -> list:
    nodes = []
    for master in node_list.get("node_list", {}).get("masters", []):
        nodes.append(master)
    for worker in node_list.get("node_list", {}).get("workers", []):
        nodes.append(worker)
    return nodes


def _install_kube_on_node(node: dict, k8s_version: str) -> None:
    """在单个节点上安装 Kubernetes 组件。"""
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
        logger.info(f"[{hostname}] 开始安装 K8s 组件 v{k8s_version}...")

        # 1. 添加 K8s YUM 仓库
        repo_content = (
            "[kubernetes]\n"
            "name=Kubernetes\n"
            "baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/"
            "kubernetes-el7-x86_64/\n"
            "enabled=1\n"
            "gpgcheck=0\n"
        )
        ssh.exec_command(
            f"cat > /etc/yum.repos.d/kubernetes.repo << 'EOF'\n{repo_content}\nEOF",
            sudo=True
        )

        # 2. 安装 kubeadm/kubectl/kubelet
        install_cmd = (
            f"yum install -y kubeadm-{k8s_version} kubectl-{k8s_version} "
            f"kubelet-{k8s_version} --disableexcludes=kubernetes"
        )
        ssh.exec_command_ok(install_cmd, sudo=True, timeout=300)
        logger.info(f"[{hostname}] K8s 组件已安装")

        # 3. 配置 kubelet cgroup 驱动
        kubelet_config = (
            'KUBELET_EXTRA_ARGS="--cgroup-driver=systemd '
            '--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock"'
        )
        ssh.exec_command(
            f"echo '{kubelet_config}' > /etc/sysconfig/kubelet",
            sudo=True
        )

        # 4. 启用 kubelet（会自动等待 kubeadm init）
        ssh.exec_command_ok("systemctl enable kubelet", sudo=True)

        logger.info(f"[{hostname}] K8s 组件安装完成 ✓")

    except KubeComponentInstallError:
        raise
    except Exception as e:
        raise KubeComponentInstallError(hostname, "kubeadm/kubectl/kubelet", str(e))
    finally:
        ssh.close()


def run_kube_components(state: WorkflowStateManager) -> None:
    """
    在全部节点上安装 Kubernetes 组件。

    Args:
        state: 工作流状态管理器实例
    """
    logger.info("=" * 50)
    logger.info("Stage 3: 开始 K8s 组件安装")
    logger.info("=" * 50)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    version_config = YAMLHelper.load(os.path.join(CONFIG_DIR, "software_version.yaml"))
    k8s_version = version_config.get("software_version", {}).get(
        "kubernetes", {}
    ).get("default", "1.29.6")

    all_nodes = _get_all_nodes(node_list)

    for node in all_nodes:
        _install_kube_on_node(node, k8s_version)

    logger.info(f"K8s 组件安装完成: {len(all_nodes)} 个节点")
    state.set_global("kube_components_installed", True)
    state.set_global("k8s_version", k8s_version)
