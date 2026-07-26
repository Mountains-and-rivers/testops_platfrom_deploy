"""
K8s Cluster Deploy — 环境预检入口

仅执行 Stage 0 环境预检扫描，不进行实际部署。
"""

import sys
import os

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from src.stages.stage0_pre_check import run_pre_check
from src.workflow.pipeline import K8sDeployPipeline

logger = get_logger(__name__)


def run_check():
    """执行环境预检扫描。"""
    pipeline = K8sDeployPipeline(workflow_type="check")
    pipeline.register_stage("stage0_pre_check", run_pre_check)
    success = pipeline.run(start_stage=0, stop_stage=0)

    if success:
        logger.info("环境预检通过 ✓")
    else:
        logger.error("环境预检未通过，请修复后重试")
        sys.exit(1)
