"""
Stage 1: 服务器系统标准化初始化

执行节点标准化操作：
- 关闭 SELinux
- 永久关闭 Swap
- 停止并禁用防火墙
- 加载内核模块 (overlay, br_netfilter)
- 配置内核参数 (sysctl)
- 配置系统资源限制 (limits.conf)
- 安装必备系统工具包
- 配置时间同步 (chronyd/ntpd)
- 配置 /etc/hosts
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
from src.workflow.workflow_exception import SystemInitError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")


def _load_configs():
    """加载所需配置。"""
    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    sys_init = YAMLHelper.load(os.path.join(CONFIG_DIR, "system_init.yaml"))
    return node_list, sys_init


def _get_all_nodes(node_list: dict) -> list:
    """从节点清单中提取所有节点（master + worker）。"""
    nodes = []
    for master in node_list.get("node_list", {}).get("masters", []):
        nodes.append(master)
    for worker in node_list.get("node_list", {}).get("workers", []):
        nodes.append(worker)
    return nodes


def _init_single_node(node: dict, sys_init: dict) -> None:
    """对单个节点执行系统初始化。"""
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
        logger.info(f"[{hostname}] 开始系统初始化...")

        init_cfg = sys_init.get("system_init", {})

        # 1. 关闭 SELinux
        selinux_cfg = init_cfg.get("selinux", {})
        mode = selinux_cfg.get("mode", "disabled")
        ssh.exec_command(f"setenforce 0 2>/dev/null; "
                         f"sed -i 's/^SELINUX=.*/SELINUX={mode}/' /etc/selinux/config",
                         sudo=True)
        logger.info(f"[{hostname}] SELinux → {mode}")

        # 2. 关闭 Swap
        if init_cfg.get("swap", {}).get("disable_permanently", True):
            ssh.exec_command("swapoff -a", sudo=True)
            ssh.exec_command("sed -i '/swap/s/^/#/' /etc/fstab", sudo=True)
            logger.info(f"[{hostname}] Swap 已关闭")

        # 3. 关闭防火墙
        fw_cfg = init_cfg.get("firewall", {})
        manager = fw_cfg.get("manager", "firewalld")
        ssh.exec_command(f"systemctl stop {manager} 2>/dev/null; "
                         f"systemctl disable {manager} 2>/dev/null",
                         sudo=True)
        logger.info(f"[{hostname}] 防火墙 ({manager}) 已停止")

        # 4. 加载内核模块
        modules = init_cfg.get("kernel_modules", {}).get("required", [])
        for mod in modules:
            ssh.exec_command(f"modprobe {mod}", sudo=True)
            ssh.exec_command(f"echo '{mod}' > /etc/modules-load.d/{mod}.conf", sudo=True)
        logger.info(f"[{hostname}] 内核模块已加载: {modules}")

        # 5. 配置内核参数
        sysctl_params = init_cfg.get("sysctl_params", {})
        sysctl_lines = [f"{k} = {v}" for k, v in sysctl_params.items()]
        sysctl_content = "\n".join(sysctl_lines)
        ssh.exec_command(
            f"cat > /etc/sysctl.d/99-kubernetes.conf << 'EOF'\n{sysctl_content}\nEOF",
            sudo=True
        )
        ssh.exec_command("sysctl --system", sudo=True)
        logger.info(f"[{hostname}] 内核参数已配置")

        # 6. 配置资源限制
        limits = init_cfg.get("limits", {})
        limits_content = "\n".join([
            f"* soft nofile {limits.get('nofile', 655360)}",
            f"* hard nofile {limits.get('nofile', 655360)}",
            f"* soft nproc {limits.get('nproc', 655360)}",
            f"* hard nproc {limits.get('nproc', 655360)}",
        ])
        ssh.exec_command(
            f"cat > /etc/security/limits.d/99-kubernetes.conf << 'EOF'\n{limits_content}\nEOF",
            sudo=True
        )
        logger.info(f"[{hostname}] 资源限制已配置")

        # 7. 配置时间同步
        ntp_cfg = init_cfg.get("ntp", {})
        if ntp_cfg.get("enabled", True):
            ntp_service = ntp_cfg.get("service", "chronyd")
            ssh.exec_command(f"systemctl enable {ntp_service} --now", sudo=True)
            logger.info(f"[{hostname}] 时间同步 ({ntp_service}) 已启动")

        # 8. 配置 /etc/hosts
        hosts_entries = init_cfg.get("hosts", {}).get("extra_entries", [])
        for entry in hosts_entries:
            ssh.exec_command(f"echo '{entry}' >> /etc/hosts", sudo=True)

        logger.info(f"[{hostname}] 系统初始化完成 ✓")

    except Exception as e:
        raise SystemInitError(hostname, "系统初始化", str(e))

    finally:
        ssh.close()


def run_sys_init(state: WorkflowStateManager) -> None:
    """
    对所有节点执行系统标准化初始化。

    Args:
        state: 工作流状态管理器实例
    """
    logger.info("=" * 50)
    logger.info("Stage 1: 开始系统标准化初始化")
    logger.info("=" * 50)

    node_list, sys_init = _load_configs()
    all_nodes = _get_all_nodes(node_list)

    for node in all_nodes:
        _init_single_node(node, sys_init)

    logger.info(f"系统初始化完成: {len(all_nodes)} 个节点全部就绪")
    state.set_global("sys_init_completed", True)
