"""
Stage 6: Calico 网络插件部署

在集群中部署 Calico CNI 网络插件：
- 下载 Calico manifest
- 按配置修改 Pod 网段
- 配置隧道模式（VXLAN / IPIP）
- kubectl apply 部署
- 等待 Calico Pods 就绪
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
from src.workflow.workflow_exception import CNIDeployError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")

# Calico 官方 manifest URL（国内可使用镜像地址）
CALICO_MANIFEST_URL = (
    "https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/"
    "manifests/calico.yaml"
)

# 国内镜像加速地址
CALICO_MANIFEST_MIRROR = (
    "https://ghproxy.com/https://raw.githubusercontent.com/projectcalico/calico/"
    "v3.27.0/manifests/calico.yaml"
)


def run_cni_deploy(state: WorkflowStateManager) -> None:
    """
    在已初始化的集群中部署 Calico 网络插件。

    Args:
        state: 工作流状态管理器实例
    """
    logger.info("=" * 50)
    logger.info("Stage 6: 开始 CNI 网络插件部署 (Calico)")
    logger.info("=" * 50)

    cluster_info = YAMLHelper.load(os.path.join(CONFIG_DIR, "cluster_info.yaml"))
    calico_cfg = cluster_info.get("cluster_info", {}).get("cni", {}).get("calico", {})

    master_ip = state.get_global("master_ip")
    if not master_ip:
        raise CNIDeployError("calico", "未找到 Master 节点 IP")

    ssh = SSHClient(host=master_ip, username="root", port=22)

    try:
        ssh.connect()

        # 1. 下载 Calico manifest
        logger.info("下载 Calico manifest...")
        # 优先使用国内镜像
        download_cmd = (
            f"curl -sL -o /tmp/calico.yaml "
            f"{CALICO_MANIFEST_MIRROR} || "
            f"curl -sL -o /tmp/calico.yaml {CALICO_MANIFEST_URL}"
        )
        exit_code, _, stderr = ssh.exec_command(download_cmd, timeout=60)
        if exit_code != 0:
            raise CNIDeployError("calico", f"manifest 下载失败: {stderr[:200]}")

        # 2. 修改 Pod 网段（如果与默认 192.168.0.0/16 不同）
        net = cluster_info.get("cluster_info", {}).get("networking", {})
        pod_cidr = net.get("pod_cidr", "10.244.0.0/16")
        if pod_cidr != "192.168.0.0/16":
            ssh.exec_command_ok(
                f"sed -i 's|192.168.0.0/16|{pod_cidr}|g' /tmp/calico.yaml",
                sudo=True
            )
            logger.info(f"Pod 网段已修改为: {pod_cidr}")

        # 3. 配置隧道模式
        encapsulation = calico_cfg.get("encapsulation", "VXLANCrossSubnet")
        # 如果选 IPIP 而不是 VXLAN
        if "IPIP" in encapsulation:
            ssh.exec_command_ok(
                "sed -i 's|vxlanMode: Always|vxlanMode: Never|' /tmp/calico.yaml",
                sudo=True
            )
            logger.info(f"隧道模式 → VXLAN (CrossSubnet)")

        # 4. 部署 Calico
        logger.info("部署 Calico...")
        exit_code, stdout, stderr = ssh.exec_command(
            "kubectl apply -f /tmp/calico.yaml", timeout=120
        )
        if exit_code != 0:
            raise CNIDeployError("calico", f"kubectl apply 失败: {stderr[:300]}")

        logger.info("Calico manifest 已应用")

        # 5. 等待 Calico Pods 就绪
        logger.info("等待 Calico Pods 就绪（最多 180 秒）...")
        wait_cmd = (
            "kubectl wait --for=condition=ready pod "
            "-l k8s-app=calico-node -n kube-system --timeout=180s && "
            "kubectl wait --for=condition=ready pod "
            "-l k8s-app=calico-kube-controllers -n kube-system --timeout=180s"
        )
        exit_code, wait_stdout, wait_stderr = ssh.exec_command(wait_cmd, timeout=200)

        if exit_code != 0:
            # 输出当前状态以便排查
            _, pod_status, _ = ssh.exec_command(
                "kubectl get pods -n kube-system | grep calico", timeout=10
            )
            logger.warning(f"Calico Pod 状态:\n{pod_status}")
            raise CNIDeployError(
                "calico", f"Pods 未能在超时时间内就绪: {wait_stderr[:200]}"
            )

        # 6. 检查节点状态
        _, node_status, _ = ssh.exec_command("kubectl get nodes", timeout=10)
        logger.info(f"节点状态:\n{node_status}")

        logger.info("Calico 网络插件部署完成 ✓")

    except CNIDeployError:
        raise
    except Exception as e:
        raise CNIDeployError("calico", str(e))
    finally:
        ssh.close()

    state.set_global("cni_deployed", True)
    state.set_global("cni_plugin", "calico")
