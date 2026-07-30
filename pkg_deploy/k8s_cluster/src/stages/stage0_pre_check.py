"""
Stage 0: 环境预检扫描

检查目标节点的：
- SSH 连通性
- OS / 内核版本
- CPU 核数、内存大小、磁盘空间
- Swap / SELinux / 防火墙状态
"""

import os
import sys
import time

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.workflow_state import WorkflowStateManager
from common.remote_executor import RemoteExecutor
from src.constants import Commands, HardwareRequirements
from src.workflow.workflow_exception import PreCheckFailedError

logger = get_logger(__name__)

BANNER = "█"
SEP = "═"


def _log_header(msg: str):
    logger.info(f"\n{BANNER * 60}")
    logger.info(f"  {msg}")
    logger.info(f"{BANNER * 60}")


def _log_step(step: str):
    logger.info(f"  ▶ {step}")


def _log_ok(msg: str):
    logger.info(f"    ✅ {msg}")


def _log_warn(msg: str):
    logger.warning(f"    ⚠️  {msg}")


def _log_fail(msg: str):
    logger.error(f"    ❌ {msg}")


def _check_single_node(executor: RemoteExecutor, node_index: int, total: int,
                       hostname: str, ip: str, role: str) -> dict:
    """对单个节点执行完整预检。"""
    logger.info(f"\n  ┌──────────────────────────────────────────┐")
    logger.info(f"  │ [{node_index}/{total}] 检查节点: {hostname} ({ip})")
    logger.info(f"  │ 角色: {role}")
    logger.info(f"  └──────────────────────────────────────────┘")

    results = {
        "hostname": hostname,
        "ip": ip,
        "role": role,
        "checks": {},
        "passed": True,
    }

    try:
        # --- 连通性 ---
        _log_step("SSH 连通性测试...")
        start = time.time()
        if not executor.test_connection(hostname):
            raise ConnectionError("SSH 连接失败，请检查 IP / 端口 / 密码")
        elapsed = (time.time() - start) * 1000
        _log_ok(f"SSH 连接成功 (耗时 {elapsed:.0f}ms)")

        # --- 系统版本 ---
        _log_step("操作系统版本...")
        _, os_release, _ = executor.exec(hostname, Commands.CHECK_SYSTEM_VERSION, timeout=10)
        results["checks"]["os_release"] = os_release[:200]
        # 提取 PRETTY_NAME
        for line in os_release.split("\n"):
            if "PRETTY_NAME" in line:
                _log_ok(f"OS: {line.split('=')[-1].strip('\"')}")
                break
        else:
            _log_ok(f"OS: {os_release[:80]}")

        # --- 内核 ---
        _log_step("内核版本...")
        _, kernel, _ = executor.exec(hostname, Commands.CHECK_KERNEL_VERSION, timeout=5)
        results["checks"]["kernel"] = kernel.strip()
        _log_ok(f"Kernel: {kernel.strip()}")

        # --- CPU ---
        _log_step("CPU 核数 (要求 ≥ {})...".format(HardwareRequirements.MIN_CPU_CORES))
        _, cpu_str, _ = executor.exec(hostname, Commands.CHECK_CPU_CORES, timeout=5)
        cpu_cores = int(cpu_str.strip())
        results["checks"]["cpu_cores"] = cpu_cores
        if cpu_cores < HardwareRequirements.MIN_CPU_CORES:
            results["passed"] = False
            _log_fail(f"CPU 不足: {cpu_cores} 核 < {HardwareRequirements.MIN_CPU_CORES} 核")
        else:
            _log_ok(f"CPU: {cpu_cores} 核")

        # --- 内存 ---
        _log_step("内存大小 (要求 ≥ {}MB)...".format(HardwareRequirements.MIN_MEMORY_MB))
        _, mem_str, _ = executor.exec(hostname, Commands.CHECK_MEMORY_MB, timeout=5)
        memory_mb = int(mem_str.strip())
        results["checks"]["memory_mb"] = memory_mb
        if memory_mb < HardwareRequirements.MIN_MEMORY_MB:
            results["passed"] = False
            _log_fail(f"内存不足: {memory_mb}MB < {HardwareRequirements.MIN_MEMORY_MB}MB")
        else:
            _log_ok(f"内存: {memory_mb}MB ({memory_mb // 1024}GB)")

        # --- 磁盘 ---
        _log_step("磁盘空间 (要求 ≥ {}GB，检查 /var/lib 或 /)...".format(HardwareRequirements.MIN_DISK_GB))
        _, disk_str, _ = executor.exec(hostname, Commands.CHECK_DISK_GB, timeout=5)
        disk_gb = int(disk_str.strip()) if disk_str.strip().isdigit() else 0
        results["checks"]["disk_gb"] = disk_gb
        if disk_gb < HardwareRequirements.MIN_DISK_GB:
            results["passed"] = False
            _log_fail(f"磁盘不足: {disk_gb}GB < {HardwareRequirements.MIN_DISK_GB}GB")
        else:
            _log_ok(f"磁盘: {disk_gb}GB")

        # 列出所有挂载点可用空间
        _, mounts, _ = executor.exec(hostname, Commands.CHECK_ALL_MOUNTS, timeout=5)
        results["checks"]["mounts"] = mounts.strip()
        logger.info(f"    📋 所有挂载点可用空间:\n{mounts.strip()}")

        # --- Swap ---
        _log_step("Swap 状态...")
        _, swap, _ = executor.exec(hostname, Commands.CHECK_SWAP, timeout=5)
        has_swap = len(swap.strip()) > 0
        results["checks"]["swap_active"] = has_swap
        if has_swap:
            _log_warn(f"Swap 已开启 (建议关闭): {swap.strip()[:80]}")
        else:
            _log_ok("Swap 已关闭")

        # --- SELinux ---
        _log_step("SELinux 状态...")
        _, selinux, _ = executor.exec(hostname, Commands.CHECK_SELINUX, timeout=5)
        results["checks"]["selinux"] = selinux.strip()
        _log_ok(f"SELinux: {selinux.strip()}")

        # --- 防火墙 ---
        _log_step("防火墙状态...")
        _, firewall, _ = executor.exec(hostname, Commands.CHECK_FIREWALL, timeout=5)
        results["checks"]["firewall"] = firewall.strip()
        _log_ok(f"Firewall: {firewall.strip()}")

        # --- 汇总 ---
        if results["passed"]:
            logger.info(f"  ┌{'─' * 50}┐")
            logger.info(f"  │  ✅  {hostname} — 预检通过")
            logger.info(f"  │  CPU={cpu_cores}核 | Mem={memory_mb}MB | Disk={disk_gb}GB")
            logger.info(f"  └{'─' * 50}┘")
        else:
            logger.error(f"  ┌{'─' * 50}┐")
            logger.error(f"  │  ❌  {hostname} — 预检未通过！")
            logger.error(f"  └{'─' * 50}┘")

    except Exception as e:
        results["passed"] = False
        results["checks"]["error"] = str(e)
        logger.error(f"  ┌{'─' * 50}┐")
        logger.error(f"  │  ❌  {hostname} — 连接/执行失败！")
        logger.error(f"  │  错误: {e}")
        logger.error(f"  │  请检查: IP地址 / SSH端口 / 用户名密码")
        logger.error(f"  └{'─' * 50}┘")

    return results


def run_pre_check(state: WorkflowStateManager) -> None:
    """执行所有节点的环境预检扫描。"""
    _log_header("🚀 K8s 集群环境预检扫描 — Stage 0")

    executor = RemoteExecutor()
    try:
        all_nodes = executor.get_all_nodes()

        if not all_nodes:
            logger.error("❌ 节点清单为空！请先配置 config/node_list.yaml")
            raise PreCheckFailedError(
                node="none",
                check_item="节点清单",
                detail="config/node_list.yaml 中无节点定义"
            )

        logger.info(f"  待检查节点: {len(all_nodes)} 个")
        for n in all_nodes:
            logger.info(f"    • {n['hostname']} ({n['ip']}) [{n.get('role', '-')}]")

        all_results = []
        all_passed = True

        for i, node in enumerate(all_nodes, 1):
            hostname = node["hostname"]
            ip = node["ip"]
            role = node.get("role", "worker")
            result = _check_single_node(executor, i, len(all_nodes), hostname, ip, role)
            all_results.append(result)
            if not result["passed"]:
                all_passed = False

        # =========== 最终汇总 ===========
        _log_header("📋 预检结果汇总")

        passed_count = sum(1 for r in all_results if r["passed"])
        failed_count = len(all_results) - passed_count

        logger.info(f"  总计: {len(all_results)} 个节点")
        logger.info(f"  通过: {passed_count} ✅")
        if failed_count > 0:
            logger.error(f"  失败: {failed_count} ❌")

        logger.info(f"\n  {'─' * 50}")
        for r in all_results:
            if r["passed"]:
                logger.info(f"  ✅ {r['hostname']:20s} ({r['ip']:15s}) [{r['role']}]")
            else:
                error_detail = r["checks"].get("error", "硬件不满足最低要求")
                logger.error(f"  ❌ {r['hostname']:20s} ({r['ip']:15s}) [{r['role']}] → {error_detail}")
        logger.info(f"  {'─' * 50}")

        state.set_global("pre_check_results", all_results)

        if not all_passed:
            failed_nodes = [r["hostname"] for r in all_results if not r["passed"]]
            raise PreCheckFailedError(
                node=",".join(failed_nodes),
                check_item="硬件/系统环境",
                detail="部分节点不满足部署最低要求"
            )
    finally:
        executor.close_all()
