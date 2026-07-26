"""
K8s Cluster Deploy — 环境预检入口

仅执行 Stage 0 环境预检扫描，不进行实际部署。
每次执行都强制重新检查，忽略缓存状态。
"""

import sys
import os

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.workflow_state import WorkflowStateManager
from src.stages.stage0_pre_check import run_pre_check
from src.constants import Paths

logger = get_logger(__name__)


def run_check():
    """执行环境预检扫描（每次强制重新检查）。"""
    # 使用独立的状态管理器，强制重置 stage0 确保每次真正执行
    state_file = os.path.join(PROJECT_ROOT, Paths.STATE_FILE)
    state = WorkflowStateManager(state_file)
    state.component_name = "k8s_cluster_deploy"
    state.workflow_type = "check"

    # ----- 流程文件状态初始化/还原 -----
    logger.info("")
    logger.info("╔" + "═" * 58 + "╗")
    logger.info("║" + "  📋 流程文件状态初始化/还原  ".center(52) + "║")
    logger.info("╚" + "═" * 58 + "╝")
    state.load()
    state.register_stages(["stage0_pre_check"])
    state.reset_from_stage("stage0_pre_check")

    # ----- 开始执行 -----
    logger.info("")
    logger.info("╔" + "═" * 58 + "╗")
    logger.info("║" + "  🔍  K8s 集群环境预检 — 开始执行  ".center(52) + "║")
    logger.info("╚" + "═" * 58 + "╝")

    try:
        state.start_stage("stage0_pre_check")
        run_pre_check(state)
        state.complete_stage("stage0_pre_check")

        logger.info("")
        logger.info("╔" + "═" * 58 + "╗")
        logger.info("║" + "  ✅  环境预检全部通过！可以执行安装  ".center(50) + "║")
        logger.info("║" + "  python module_main.py install          ".center(50) + "║")
        logger.info("╚" + "═" * 58 + "╝")
        logger.info("")

    except Exception as e:
        state.fail_stage("stage0_pre_check", str(e))

        logger.error("")
        logger.error("╔" + "═" * 58 + "╗")
        logger.error("║" + "  ❌  环境预检未通过！请修复后重试  ".center(50) + "║")
        logger.error("║" + "  python module_main.py check             ".center(50) + "║")
        logger.error("╚" + "═" * 58 + "╝")
        logger.error("")
        sys.exit(1)
