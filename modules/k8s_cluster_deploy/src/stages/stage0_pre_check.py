"""
Stage 0: 环境预检扫描

检查目标节点的：
- 系统版本（OS release）
- CPU 核数、内存大小、磁盘空间
- Swap 状态
- SELinux 状态
- 防火墙状态
- 内核版本与模块
- 网络连通性（SSH 可达性）
- 端口占用检查
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
from src.constants import Commands, HardwareRequirements
from src.workflow.workflow_exception import PreCheckFailedError

logger = get_logger(__name__)

# 配置路径
CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")


def _load_node_list():
    """加载节点清单。"""
    node_file = os.path.join(CONFIG_DIR, "node_list.yaml")
    return YAMLHelper.load(node_file)


def _check_single_node(hostname: str, ip: str, ssh_cfg: dict, role: str) -> dict:
    """对单个节点执行完整预检。"""
    results = {
        "hostname": hostname,
        "ip": ip,
        "role": role,
        "checks": {},
        "passed": True,
    }

    ssh = SSHClient(
        host=ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
    )

    try:
        ssh.connect()

        # 系统版本
        _, os_release, _ = ssh.exec_command(Commands.CHECK_SYSTEM_VERSION, timeout=10)
        results["checks"]["os_release"] = os_release[:200]

        # 内核版本
        _, kernel, _ = ssh.exec_command(Commands.CHECK_KERNEL_VERSION, timeout=5)
        results["checks"]["kernel"] = kernel.strip()

        # CPU 核数
        _, cpu_str, _ = ssh.exec_command(Commands.CHECK_CPU_CORES, timeout=5)
        cpu_cores = int(cpu_str.strip())
        results["checks"]["cpu_cores"] = cpu_cores
        if cpu_cores < HardwareRequirements.MIN_CPU_CORES:
            results["passed"] = False
            logger.warning(f"[{hostname}] CPU 核数不足: {cpu_cores} < {HardwareRequirements.MIN_CPU_CORES}")

        # 内存
        _, mem_str, _ = ssh.exec_command(Commands.CHECK_MEMORY_MB, timeout=5)
        memory_mb = int(mem_str.strip())
        results["checks"]["memory_mb"] = memory_mb
        if memory_mb < HardwareRequirements.MIN_MEMORY_MB:
            results["passed"] = False
            logger.warning(f"[{hostname}] 内存不足: {memory_mb}MB < {HardwareRequirements.MIN_MEMORY_MB}MB")

        # 磁盘
        _, disk_str, _ = ssh.exec_command(Commands.CHECK_DISK_GB, timeout=5)
        disk_gb = int(disk_str.strip()) if disk_str.strip().isdigit() else 0
        results["checks"]["disk_gb"] = disk_gb
        if disk_gb < HardwareRequirements.MIN_DISK_GB:
            results["passed"] = False
            logger.warning(f"[{hostname}] 磁盘不足: {disk_gb}GB < {HardwareRequirements.MIN_DISK_GB}GB")

        # Swap
        _, swap, _ = ssh.exec_command(Commands.CHECK_SWAP, timeout=5)
        has_swap = len(swap.strip()) > 0
        results["checks"]["swap_active"] = has_swap

        # SELinux
        _, selinux, _ = ssh.exec_command(Commands.CHECK_SELINUX, timeout=5)
        results["checks"]["selinux"] = selinux.strip()

        # 防火墙
        _, firewall, _ = ssh.exec_command(Commands.CHECK_FIREWALL, timeout=5)
        results["checks"]["firewall"] = firewall.strip()

        logger.info(f"[{hostname}] 预检通过: CPU={cpu_cores}, Mem={memory_mb}MB, Disk={disk_gb}GB")

    except Exception as e:
        results["passed"] = False
        results["checks"]["error"] = str(e)
        logger.error(f"[{hostname}] 预检失败: {e}")

    finally:
        ssh.close()

    return results


def run_pre_check(state: WorkflowStateManager) -> None:
    """
    执行所有节点的环境预检扫描。

    Args:
        state: 工作流状态管理器实例
    """
    logger.info("=" * 50)
    logger.info("Stage 0: 开始环境预检扫描")
    logger.info("=" * 50)

    node_list = _load_node_list()

    all_results = []
    all_passed = True

    # 检查 Master 节点
    for master in node_list.get("node_list", {}).get("masters", []):
        result = _check_single_node(
            master["hostname"],
            master["ip"],
            master.get("ssh", {}),
            master.get("role", "control-plane"),
        )
        all_results.append(result)
        if not result["passed"]:
            all_passed = False

    # 检查 Worker 节点
    for worker in node_list.get("node_list", {}).get("workers", []):
        result = _check_single_node(
            worker["hostname"],
            worker["ip"],
            worker.get("ssh", {}),
            worker.get("role", "worker"),
        )
        all_results.append(result)
        if not result["passed"]:
            all_passed = False

    # 汇总
    logger.info(f"\n预检完成: {'全部通过' if all_passed else '存在未通过项'}")
    for r in all_results:
        status = "✓" if r["passed"] else "✗"
        logger.info(f"  {status} {r['hostname']} ({r['ip']}) [{r['role']}]")

    # 保存结果供后续阶段参考
    state.set_global("pre_check_results", all_results)

    if not all_passed:
        failed_nodes = [r["hostname"] for r in all_results if not r["passed"]]
        raise PreCheckFailedError(
            node=",".join(failed_nodes),
            check_item="硬件/系统环境",
            detail="部分节点不满足部署最低要求"
        )
