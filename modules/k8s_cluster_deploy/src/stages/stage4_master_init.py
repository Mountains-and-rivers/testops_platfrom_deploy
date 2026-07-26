"""
Stage 4: Master 节点集群初始化

执行 kubeadm init：
- 生成 kubeadm 初始化配置文件
- 执行 kubeadm init
- 配置 kubectl（复制 admin.conf 到 ~/.kube/config）
- 保存 join token 供后续 Node 加入使用
- 移除 Master 节点污点（如配置要求可调度）
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
from src.workflow.workflow_exception import MasterInitError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")
TEMP_CACHE_DIR = os.path.join(
    os.path.dirname(os.path.dirname(__file__)), "runtime", "temp_cache"
)


def run_master_init(state: WorkflowStateManager) -> None:
    """
    初始化第一个 Master 节点。

    Args:
        state: 工作流状态管理器实例
    """
    logger.info("=" * 50)
    logger.info("Stage 4: 开始 Master 节点集群初始化")
    logger.info("=" * 50)

    # 加载配置
    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    cluster_info = YAMLHelper.load(os.path.join(CONFIG_DIR, "cluster_info.yaml"))

    masters = node_list.get("node_list", {}).get("masters", [])
    if not masters:
        raise MasterInitError("none", "未找到 Master 节点定义")

    # 取第一个 Master 作为初始控制平面节点
    master = masters[0]
    hostname = master["hostname"]
    ip = master["ip"]
    ssh_cfg = master.get("ssh", {})

    net = cluster_info.get("cluster_info", {}).get("networking", {})
    pod_cidr = net.get("pod_cidr", "10.244.0.0/16")
    service_cidr = net.get("service_cidr", "10.96.0.0/12")
    api_endpoint = cluster_info.get("cluster_info", {}).get(
        "api_server", {}
    ).get("control_plane_endpoint", f"{ip}:6443")

    ssh = SSHClient(
        host=ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
    )

    try:
        ssh.connect()
        logger.info(f"[{hostname}] 开始 Master 节点初始化...")

        # 1. 生成 kubeadm init 配置文件
        kubeadm_config = f"""apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: {ip}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  name: {hostname}
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v{state.get_global('k8s_version', '1.29.6')}
controlPlaneEndpoint: "{api_endpoint}"
networking:
  podSubnet: "{pod_cidr}"
  serviceSubnet: "{service_cidr}"
  dnsDomain: "cluster.local"
apiServer:
  certSANs:
    - "{ip}"
    - "{hostname}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
"""

        ssh.exec_command(
            f"cat > /tmp/kubeadm-init.yaml << 'EOF'\n{kubeadm_config}\nEOF",
            sudo=True
        )
        logger.info(f"[{hostname}] kubeadm 配置文件已生成")

        # 2. 执行 kubeadm init
        logger.info(f"[{hostname}] 执行 kubeadm init（可能需要几分钟）...")
        exit_code, stdout, stderr = ssh.exec_command(
            "kubeadm init --config=/tmp/kubeadm-init.yaml --upload-certs",
            sudo=True,
            timeout=600,
        )

        if exit_code != 0:
            raise MasterInitError(hostname, f"kubeadm init 失败: {stderr[:500]}")

        logger.info(f"[{hostname}] kubeadm init 成功 ✓")

        # 3. 配置 kubectl
        ssh.exec_command_ok(
            "mkdir -p $HOME/.kube && "
            "cp /etc/kubernetes/admin.conf $HOME/.kube/config && "
            "chown $(id -u):$(id -g) $HOME/.kube/config",
            sudo=False
        )
        logger.info(f"[{hostname}] kubectl 已配置")

        # 4. 生成并保存 join token
        _, join_cmd, _ = ssh.exec_command(
            "kubeadm token create --print-join-command", sudo=True
        )
        join_cmd = join_cmd.strip()
        logger.info(f"[{hostname}] Join 命令已生成: {join_cmd[:80]}...")

        # 保存 join 命令到本地缓存
        os.makedirs(TEMP_CACHE_DIR, exist_ok=True)
        cache_file = os.path.join(TEMP_CACHE_DIR, "join_command.sh")
        with open(cache_file, "w") as f:
            f.write(join_cmd)

        # 存入状态供后续阶段使用
        state.set_global("join_command", join_cmd)
        state.set_global("master_ip", ip)
        state.set_global("master_hostname", hostname)

        # 5. （可选）移除 Master 污点以允许调度
        taints = master.get("taints", [])
        if not taints:
            ssh.exec_command(
                "kubectl taint nodes --all node-role.kubernetes.io/control-plane-",
                timeout=10
            )
            logger.info(f"[{hostname}] Master 节点污点已移除（允许调度）")

        logger.info(f"[{hostname}] Master 节点初始化完成 ✓")

    except MasterInitError:
        raise
    except Exception as e:
        raise MasterInitError(hostname, str(e))
    finally:
        ssh.close()
