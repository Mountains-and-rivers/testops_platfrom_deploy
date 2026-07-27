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


def _init_single_node(node: dict, sys_init: dict, hosts_block: str) -> None:
    """对单个节点执行系统初始化。"""
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
        logger.info(f"[{hostname}] 开始系统初始化...")

        init_cfg = sys_init.get("system_init", {})

        # 1. 关闭 SELinux
        selinux_cfg = init_cfg.get("selinux", {})
        mode = selinux_cfg.get("mode", "disabled")
        ssh.exec_command(f"setenforce 0 2>/dev/null; "
                         f"sed -i 's/^SELINUX=.*/SELINUX={mode}/' /etc/selinux/config",
                         sudo=False)
        logger.info(f"[{hostname}] SELinux → {mode}")

        # 2. 关闭 Swap（只注释未注释的 swap 行，可重复执行）
        if init_cfg.get("swap", {}).get("disable_permanently", True):
            ssh.exec_command("swapoff -a", sudo=False)
            # 只匹配不以 # 开头的 swap 行，避免重复注释
            ssh.exec_command("sed -i '/^[^#].*swap/s/^/#/' /etc/fstab", sudo=False)
            logger.info(f"[{hostname}] Swap 已关闭")

        # 3. 关闭防火墙
        fw_cfg = init_cfg.get("firewall", {})
        manager = fw_cfg.get("manager", "firewalld")
        ssh.exec_command(f"systemctl stop {manager} 2>/dev/null; "
                         f"systemctl disable {manager} 2>/dev/null",
                         sudo=False)
        logger.info(f"[{hostname}] 防火墙 ({manager}) 已停止")

        # 4. 加载内核模块
        modules = init_cfg.get("kernel_modules", {}).get("required", [])
        for mod in modules:
            ssh.exec_command(f"modprobe {mod}", sudo=False)
            ssh.exec_command(f"echo '{mod}' > /etc/modules-load.d/{mod}.conf", sudo=False)
        logger.info(f"[{hostname}] 内核模块已加载: {modules}")

        # 5. 配置内核参数
        sysctl_params = init_cfg.get("sysctl_params", {})
        sysctl_lines = [f"{k} = {v}" for k, v in sysctl_params.items()]
        sysctl_content = "\n".join(sysctl_lines)
        ssh.exec_command(
            f"cat > /etc/sysctl.d/99-kubernetes.conf << 'EOF'\n{sysctl_content}\nEOF",
            sudo=False
        )
        ssh.exec_command("sysctl --system", sudo=False)
        logger.info(f"[{hostname}] 内核参数已配置")

        # 6. 配置资源限制
        limits = init_cfg.get("limits", {})
        limits_lines = [
            f"* soft nofile {limits.get('nofile', 655360)}",
            f"* hard nofile {limits.get('nofile', 655360)}",
            f"* soft nproc {limits.get('nproc', 655360)}",
            f"* hard nproc {limits.get('nproc', 655360)}",
        ]
        if limits.get("core"):
            limits_lines.append(f"* soft core {limits['core']}")
            limits_lines.append(f"* hard core {limits['core']}")
        if limits.get("memlock"):
            limits_lines.append(f"* soft memlock {limits['memlock']}")
            limits_lines.append(f"* hard memlock {limits['memlock']}")
        limits_content = "\n".join(limits_lines)
        ssh.exec_command(
            f"cat > /etc/security/limits.d/99-kubernetes.conf << 'EOF'\n{limits_content}\nEOF",
            sudo=False
        )
        logger.info(f"[{hostname}] 资源限制已配置")

        # 7. 配置时间同步（含 NTP 服务器）
        ntp_cfg = init_cfg.get("ntp", {})
        if ntp_cfg.get("enabled", True):
            ntp_service = ntp_cfg.get("service", "chronyd")
            ntp_servers = ntp_cfg.get("servers", [])
            if ntp_servers:
                # 用标记块替换 chrony.conf 中的 server 配置，避免重复写入
                server_lines = "\n".join([f"server {s} iburst" for s in ntp_servers])
                ssh.exec_command(
                    f"sed -i '/^# BEGIN_K8S_NTP$/,/^# END_K8S_NTP$/d' /etc/chrony.conf; "
                    f"echo '# BEGIN_K8S_NTP' >> /etc/chrony.conf; "
                    f"echo '{server_lines}' >> /etc/chrony.conf; "
                    f"echo '# END_K8S_NTP' >> /etc/chrony.conf",
                    sudo=False
                )
            ssh.exec_command(f"systemctl enable {ntp_service} --now 2>/dev/null; "
                           f"systemctl restart {ntp_service} 2>/dev/null",
                           sudo=False)
            logger.info(f"[{hostname}] 时间同步 ({ntp_service}) 已配置，服务器: {ntp_servers}")

        # 8. 配置 /etc/hosts（标记块，防重复）
        if hosts_block:
            ssh.exec_command(
                "sed -i '/^# BEGIN_K8S_HOSTS$/,/^# END_K8S_HOSTS$/d' /etc/hosts",
                sudo=False
            )
            ssh.exec_command(
                f"echo '{hosts_block}' >> /etc/hosts",
                sudo=False
            )

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
    # 前置校验：Stage 0 必须已通过
    pre_check_data = state.require_stage_success("stage0_pre_check")
    pre_check_results = pre_check_data.get("pre_check_results", [])
    failed_nodes = [r for r in pre_check_results if not r.get("passed")]
    if failed_nodes:
        failed_names = [r["hostname"] for r in failed_nodes]
        raise SystemInitError(
            f"Stage 0 预检未全部通过，以下节点不满足要求: {failed_names}，"
            f"请修复后重新执行 python module_main.py check"
        )

    logger.info("=" * 50)
    logger.info("Stage 1: 开始系统标准化初始化")
    logger.info("=" * 50)

    node_list, sys_init = _load_configs()
    all_nodes = _get_all_nodes(node_list)

    # 预生成 /etc/hosts 块（基于 node_list.yaml）
    hosts_entries = sys_init.get("system_init", {}).get("hosts", {}).get("extra_entries", [])
    hosts_lines = ["# BEGIN_K8S_HOSTS"]
    for n in all_nodes:
        hosts_lines.append(f"{n['ip']} {n['hostname']}")
    for entry in hosts_entries:
        hosts_lines.append(entry)
    hosts_lines.append("# END_K8S_HOSTS")
    hosts_block = "\n".join(hosts_lines)

    for node in all_nodes:
        _init_single_node(node, sys_init, hosts_block)

    logger.info(f"系统初始化完成: {len(all_nodes)} 个节点全部就绪")
    state.set_global("sys_init_completed", True)


def rollback_sys_init(state: WorkflowStateManager) -> None:
    """
    回滚 Stage 1：恢复系统初始化所做的修改。

    操作：
    - 恢复 SELinux 为 enforcing
    - 恢复 swap（取消注释 /etc/fstab）
    - 重新启动防火墙
    - 移除内核模块加载配置
    - 删除 sysctl 和 limits 配置文件
    """
    logger.info("=" * 50)
    logger.info("Stage 1 Rollback: 回滚系统初始化")
    logger.info("=" * 50)

    node_list, sys_init = _load_configs()
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
            logger.info(f"[{hostname}] 开始回滚系统初始化...")

            # 1. 恢复 SELinux
            ssh.exec_command(
                "sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config",
                sudo=False
            )
            logger.info(f"[{hostname}] SELinux → enforcing")

            # 2. 恢复 swap
            ssh.exec_command(
                "sed -i '/^#.*swap/s/^#//' /etc/fstab",
                sudo=False
            )
            ssh.exec_command("swapon -a 2>/dev/null || true", sudo=False)
            logger.info(f"[{hostname}] Swap 已恢复")

            # 3. 恢复防火墙
            fw_cfg = sys_init.get("system_init", {}).get("firewall", {})
            manager = fw_cfg.get("manager", "firewalld")
            ssh.exec_command(
                f"systemctl enable {manager} --now 2>/dev/null || true",
                sudo=False
            )
            logger.info(f"[{hostname}] 防火墙 ({manager}) 已恢复")

            # 4. 删除内核模块加载配置
            modules = sys_init.get("system_init", {}).get("kernel_modules", {}).get("required", [])
            for mod in modules:
                ssh.exec_command(f"rm -f /etc/modules-load.d/{mod}.conf", sudo=False)
            logger.info(f"[{hostname}] 内核模块配置已移除")

            # 5. 删除 sysctl 配置
            ssh.exec_command("rm -f /etc/sysctl.d/99-kubernetes.conf", sudo=False)
            ssh.exec_command("sysctl --system 2>/dev/null || true", sudo=False)

            # 6. 删除 limits 配置
            ssh.exec_command("rm -f /etc/security/limits.d/99-kubernetes.conf", sudo=False)

            # 7. 清理 /etc/hosts 中的 K8S 标记块
            ssh.exec_command(
                "sed -i '/^# BEGIN_K8S_HOSTS$/,/^# END_K8S_HOSTS$/d' /etc/hosts",
                sudo=False
            )

            # 8. 清理 chrony 中的 NTP 标记块，停止 chronyd
            ssh.exec_command(
                "sed -i '/^# BEGIN_K8S_NTP$/,/^# END_K8S_NTP$/d' /etc/chrony.conf",
                sudo=False
            )
            ssh.exec_command("systemctl disable chronyd --now 2>/dev/null || true", sudo=False)

            logger.info(f"[{hostname}] 系统初始化回滚完成 ✓")

        except Exception as e:
            logger.warning(f"[{hostname}] 回滚时出现错误（可忽略）: {e}")
        finally:
            ssh.close()

    logger.info("系统初始化回滚完成")
    state.set_global("sys_init_completed", False)
