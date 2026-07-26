"""
K8s Cluster Deploy — 完整卸载入口

逆序执行集群销毁流程：
1. 逐出 Worker 节点上的 Pods
2. 从集群中移除 Worker 节点
3. 删除 CNI 网络插件
4. 逐出 Master 节点 Pods（如有）
5. kubeadm reset Master
6. 卸载 K8s 组件包
7. 卸载容器运行时
8. 清理系统残留配置
"""

import sys
import os

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.yaml_helper import YAMLHelper
from common.ssh_client import SSHClient
from common.workflow_state import WorkflowStateManager
from src.constants import Paths

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(__file__), "config")


def _get_all_nodes(node_list: dict) -> list:
    """提取所有节点（逆序：worker 先，master 后）。"""
    nodes = []
    for worker in node_list.get("node_list", {}).get("workers", []):
        nodes.append(("worker", worker))
    for master in node_list.get("node_list", {}).get("masters", []):
        nodes.append(("master", master))
    return nodes


def run_uninstall():
    """
    执行 K8s 集群完整卸载。

    逆序执行：先清理 worker 节点，再清理 master 节点。
    """
    logger.info("=" * 60)
    logger.info("  K8s 集群卸载开始")
    logger.info("=" * 60)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    uninstall_rules = YAMLHelper.load(os.path.join(CONFIG_DIR, "uninstall_rules.yaml"))
    rules = uninstall_rules.get("uninstall_rules", {})

    all_nodes = _get_all_nodes(node_list)
    masters = node_list.get("node_list", {}).get("masters", [])
    workers = node_list.get("node_list", {}).get("workers", [])

    if not masters:
        logger.error("未找到 Master 节点定义")
        sys.exit(1)

    master = masters[0]
    master_ip = master["ip"]
    master_ssh_cfg = master.get("ssh", {})

    # ----- 连接到 Master 节点来执行 kubectl 操作 -----
    master_ssh = SSHClient(
        host=master_ip,
        username=master_ssh_cfg.get("username", "root"),
        port=master_ssh_cfg.get("port", 22),
    )

    try:
        master_ssh.connect()

        # 1. 逐出 Worker 节点
        if workers:
            logger.info("步骤 1: 逐出 Worker 节点上的 Pods...")
            drain_cfg = rules.get("drain_worker_nodes", {})
            timeout = drain_cfg.get("timeout", 300)

            for worker in workers:
                hostname = worker["hostname"]
                flags = "--delete-emptydir-data"
                if drain_cfg.get("force", True):
                    flags += " --force"
                if drain_cfg.get("ignore_daemonsets", True):
                    flags += " --ignore-daemonsets"

                logger.info(f"  逐出节点: {hostname}...")
                master_ssh.exec_command(
                    f"kubectl drain {hostname} {flags} --timeout={timeout}s",
                    timeout=timeout + 30
                )

            # 2. 删除 Worker 节点
            logger.info("步骤 2: 从集群移除 Worker 节点...")
            for worker in workers:
                hostname = worker["hostname"]
                master_ssh.exec_command(f"kubectl delete node {hostname}", timeout=30)
                logger.info(f"  节点已移除: {hostname}")

        # 3. 删除 CNI
        logger.info("步骤 3: 删除 CNI 网络插件...")
        master_ssh.exec_command(
            "kubectl delete -f /tmp/calico.yaml 2>/dev/null || true", timeout=60
        )

        # 4. kubeadm reset master
        logger.info("步骤 4: kubeadm reset Master 节点...")
        reset_flags = " ".join(
            rules.get("reset_master", {}).get("kubeadm_reset_flags", ["--force"])
        )
        master_ssh.exec_command(f"kubeadm reset {reset_flags}", sudo=True, timeout=120)
        logger.info(f"  Master 节点已重置: {master['hostname']}")

    finally:
        master_ssh.close()

    # 5. 在所有节点上卸载 K8s 组件和容器运行时
    logger.info("步骤 5-7: 在所有节点上卸载软件包...")
    for role, node in all_nodes:
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
            logger.info(f"  清理节点: {hostname} ({role})")

            # 卸载 K8s 组件
            ssh.exec_command(
                "yum remove -y kubeadm kubectl kubelet 2>/dev/null; "
                "apt-get remove -y kubeadm kubectl kubelet 2>/dev/null || true",
                sudo=True, timeout=120
            )

            # 停止并卸载 containerd
            ssh.exec_command("systemctl stop containerd 2>/dev/null || true", sudo=True)
            ssh.exec_command(
                "yum remove -y containerd.io 2>/dev/null; "
                "apt-get remove -y containerd.io 2>/dev/null || true",
                sudo=True, timeout=60
            )

            # 清理残留目录
            cleanup_dirs = rules.get("cleanup_system", {}).get(
                "cleanup_directories", []
            )
            for d in cleanup_dirs:
                ssh.exec_command(f"rm -rf {d}", sudo=True)

            # 清理 CNI 接口
            if rules.get("cleanup_system", {}).get("cleanup_cni_interfaces", True):
                ssh.exec_command(
                    "ip link delete cni0 2>/dev/null; "
                    "ip link delete flannel.1 2>/dev/null; "
                    "ip link delete cali* 2>/dev/null || true",
                    sudo=True
                )

            # 清理 iptables 规则
            if rules.get("cleanup_system", {}).get("cleanup_iptables", True):
                ssh.exec_command(
                    "iptables -F && iptables -t nat -F && "
                    "iptables -t mangle -F && iptables -X",
                    sudo=True
                )

            logger.info(f"  节点清理完成: {hostname} ✓")

        finally:
            ssh.close()

    logger.info("=" * 60)
    logger.info("  K8s 集群卸载完成")
    logger.info("=" * 60)
