"""
K8s Cluster Deploy — 模块内常量与阶段枚举定义
"""

from enum import Enum


# ============================================================
# 部署阶段枚举
# ============================================================
class DeployStage(Enum):
    """K8s 集群部署的 8 个阶段。"""
    STAGE0_PRE_CHECK = (0, "stage0_pre_check", "环境预检扫描")
    STAGE1_SYS_INIT = (1, "stage1_sys_init", "系统标准化初始化")
    STAGE2_CONTAINERD_SETUP = (2, "stage2_containerd_setup", "容器运行时安装配置")
    STAGE3_KUBE_COMPONENTS = (3, "stage3_kube_components", "kubeadm/kubectl/kubelet 安装")
    STAGE4_MASTER_INIT = (4, "stage4_master_init", "Master 节点集群初始化")
    STAGE5_NODE_JOIN = (5, "stage5_node_join", "Node 节点加入集群")
    STAGE6_CNI_DEPLOY = (6, "stage6_cni_deploy", "Calico 网络插件部署")
    STAGE7_CLUSTER_VERIFY = (7, "stage7_cluster_verify", "集群部署后健康校验")

    def __init__(self, order, stage_name, description):
        self.order = order
        self.stage_name = stage_name
        self.description = description

    @classmethod
    def get_ordered_stages(cls):
        """返回按顺序排列的所有阶段。"""
        return sorted(cls, key=lambda s: s.order)


# ============================================================
# 节点角色枚举
# ============================================================
class NodeRole(Enum):
    MASTER = "control-plane"
    WORKER = "worker"
    ETCD = "etcd"


# ============================================================
# 路径常量
# ============================================================
class Paths:
    """模块内路径常量。"""
    # 模块根目录
    MODULE_DIR = "pkg_deploy/k8s_cluster"
    # 配置目录
    CONFIG_DIR = f"{MODULE_DIR}/config"
    # 运行时目录
    RUNTIME_DIR = f"{MODULE_DIR}/runtime"
    # 日志目录
    LOG_DIR = f"{RUNTIME_DIR}/logs"
    # 临时缓存目录
    TEMP_CACHE_DIR = f"{RUNTIME_DIR}/temp_cache"
    # 报告输出目录
    REPORTS_DIR = f"{MODULE_DIR}/reports"
    # 工作流状态文件
    STATE_FILE = f"{RUNTIME_DIR}/workflow.state"
    # Shell 脚本目录
    SHELL_DIR = f"{MODULE_DIR}/scripts/shell"

    # 远程目标路径
    REMOTE_K8S_CONFIG_DIR = "/etc/kubernetes"
    REMOTE_CONTAINERD_CONFIG_DIR = "/etc/containerd"
    REMOTE_CNI_CONFIG_DIR = "/etc/cni/net.d"
    REMOTE_KUBELET_DATA_DIR = "/var/lib/kubelet"
    REMOTE_CONTAINERD_DATA_DIR = "/var/lib/containerd"


# ============================================================
# 命令 / 字符串常量
# ============================================================
class Commands:
    """远程执行的命令常量。"""
    CHECK_SYSTEM_VERSION = "cat /etc/os-release"
    CHECK_KERNEL_VERSION = "uname -r"
    CHECK_CPU_CORES = "nproc"
    CHECK_MEMORY_MB = "free -m | awk '/^Mem:/{print $2}'"
    # 检查 /var/lib 所在分区的可用空间（K8s/containerd 数据实际存放位置）
    # 如果 /var/lib 是独立挂载点则检查它，否则回退到 /
    CHECK_DISK_GB = (
        "mountpoint -q /var/lib 2>/dev/null && "
        "df -BG /var/lib | awk 'NR==2{print $4}' | tr -d 'G' || "
        "df -BG / | awk 'NR==2{print $4}' | tr -d 'G'"
    )
    # 列出所有挂载点及可用空间（用于预检报告参考）
    CHECK_ALL_MOUNTS = "df -h --output=target,avail | tail -n +2"
    CHECK_SWAP = "swapon --show"
    CHECK_SELINUX = "getenforce"
    CHECK_FIREWALL = "systemctl is-active firewalld 2>/dev/null || echo inactive"
    CHECK_KUBELET = "systemctl is-active kubelet 2>/dev/null || echo inactive"


# ============================================================
# 硬件最低要求
# ============================================================
class HardwareRequirements:
    """部署 K8s 集群的硬件最低要求。"""
    MIN_CPU_CORES = 2                     # Master 建议 4 核
    MIN_MEMORY_MB = 2048                  # Master 建议 4096 MB
    MIN_DISK_GB = 30                      # /var/lib 可用空间，建议 >= 100 GB
    RECOMMENDED_CPU_MASTER = 4
    RECOMMENDED_MEMORY_MASTER = 4096
    RECOMMENDED_DISK_GB = 100
