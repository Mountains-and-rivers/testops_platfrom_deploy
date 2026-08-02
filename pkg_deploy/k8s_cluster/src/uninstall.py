"""
K8s Cluster Deploy — 完整卸载入口

逆序清理：Stage 7→1，确保无残留
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

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")


def _ssh_for_node(node: dict):
    """创建 SSH 客户端"""
    cfg = node.get("ssh", {})
    return SSHClient(
        host=node["ip"],
        username=cfg.get("username", "root"),
        port=cfg.get("port", 22),
        password=cfg.get("password"),
        key_file=cfg.get("key_file"),
    )


def run_uninstall():
    """完整卸载 K8s 集群：逆序回滚 Stage 7→1，Stage 0 只读跳过"""
    logger.info("=" * 60)
    logger.info("  K8s 集群完整卸载开始（Stage 7 → Stage 1）")
    logger.info("=" * 60)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    masters = node_list.get("node_list", {}).get("masters", [])
    workers = node_list.get("node_list", {}).get("workers", [])
    all_nodes = masters + workers

    if not masters:
        logger.error("未找到 Master 节点定义")
        sys.exit(1)

    master = masters[0]
    master_ssh = _ssh_for_node(master)

    # ---- Stage 7: 清理测试资源 ----
    logger.info("[7] 清理测试 namespace...")
    from src.stages.stage7_cluster_verify import rollback_cluster_verify
    state = WorkflowStateManager(
        os.path.join(PROJECT_ROOT, Paths.STATE_FILE)
    )
    state.load()
    state.set_global("master_ip", master["ip"])
    try:
        rollback_cluster_verify(state)
    except Exception as e:
        logger.warning(f"Stage 7 回滚异常: {e}")

    # ---- Stage 6: 删除 CNI ----
    logger.info("[6] 删除 Calico CNI...")
    from src.stages.stage6_cni_deploy import rollback_cni_deploy
    try:
        rollback_cni_deploy(state)
    except Exception as e:
        logger.warning(f"Stage 6 回滚异常: {e}")

    # ---- Stage 5: 移除 Worker 节点 ----
    logger.info("[5] 移除 Worker 节点...")
    from src.stages.stage5_node_join import rollback_node_join
    try:
        rollback_node_join(state)
    except Exception as e:
        logger.warning(f"Stage 5 回滚异常: {e}")

    # ---- Stage 4: kubeadm reset Master ----
    logger.info("[4] kubeadm reset Master...")
    from src.stages.stage4_master_init import rollback_master_init
    try:
        rollback_master_init(state)
    except Exception as e:
        logger.warning(f"Stage 4 回滚异常: {e}")

    # ---- Stage 3+2: 卸载 K8s 组件 + containerd (所有节点) ----
    logger.info("[3/2] 卸载 K8s 组件 + containerd...")
    for node in all_nodes:
        hostname = node["hostname"]
        ssh = _ssh_for_node(node)
        try:
            ssh.connect()
            # 卸载 kubelet/kubeadm/kubectl + 删仓库
            ssh.exec_command(
                "yum remove -y kubeadm kubectl kubelet 2>/dev/null; "
                "apt-get remove -y kubeadm kubectl kubelet 2>/dev/null || true; "
                "rm -f /etc/yum.repos.d/kubernetes.repo 2>/dev/null || true",
                sudo=False, timeout=120
            )
            # 停止 containerd
            ssh.exec_command("systemctl stop containerd 2>/dev/null || true; systemctl stop kubelet 2>/dev/null || true", timeout=10)
            # 卸载 containerd
            ssh.exec_command(
                "yum remove -y containerd.io 2>/dev/null; "
                "apt-get remove -y containerd.io 2>/dev/null || true",
                sudo=False, timeout=60
            )
            # 删除 K8s 镜像
            ssh.exec_command(
                "ctr -n k8s.io image ls -q 2>/dev/null | xargs -r -n1 ctr -n k8s.io image remove 2>/dev/null || true",
                timeout=30
            )
            # 清理残余目录 + iptables
            ssh.exec_command(
                "rm -rf /etc/kubernetes/ /etc/cni/ /var/lib/kubelet/ /var/lib/etcd/ /var/lib/cni/ "
                "/etc/containerd/ /root/.kube/ /etc/cni/net.d/ 2>/dev/null || true; "
                "iptables -F 2>/dev/null || true; iptables -t nat -F 2>/dev/null || true; "
                "iptables -t mangle -F 2>/dev/null || true; iptables -X 2>/dev/null || true",
                sudo=False, timeout=30
            )
            # 清理 CNI 接口
            ssh.exec_command(
                "ip link delete cni0 2>/dev/null || true; "
                "ip link delete flannel.1 2>/dev/null || true; "
                "ip link delete cali* 2>/dev/null || true; "
                "ip link delete vxlan.calico 2>/dev/null || true",
                sudo=False, timeout=10
            )
            logger.info(f"  {hostname} 清理完成")
        except Exception as e:
            logger.warning(f"  {hostname} 清理异常: {e}")
        finally:
            ssh.close()

    # ---- Stage 1: 系统初始化回滚 ----
    logger.info("[1] 系统初始化回滚...")
    from src.stages.stage1_sys_init import rollback_sys_init
    try:
        rollback_sys_init(state)
    except Exception as e:
        logger.warning(f"Stage 1 回滚异常: {e}")

    # 删除本地缓存
    temp_cache = os.path.join(PROJECT_ROOT, Paths.TEMP_CACHE_DIR)
    if os.path.exists(temp_cache):
        for f in os.listdir(temp_cache):
            os.remove(os.path.join(temp_cache, f))

    # 重置状态文件
    state_file = os.path.join(PROJECT_ROOT, Paths.STATE_FILE)
    if os.path.exists(state_file):
        os.remove(state_file)
        logger.info(f"状态文件已删除: {state_file}")

    logger.info("=" * 60)
    logger.info("  K8s 集群卸载完成 — 无残留")
    logger.info("=" * 60)
