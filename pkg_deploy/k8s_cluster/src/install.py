"""
K8s Cluster Deploy — 完整安装入口

按顺序执行全部 8 个部署阶段。
"""

import sys
import os

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from src.workflow.pipeline import K8sDeployPipeline

logger = get_logger(__name__)


def run_install(start_stage: int = 0, reset_state: bool = True):
    """
    执行完整 K8s 集群部署流水线。

    Args:
        start_stage: 起始阶段编号（0-based），默认从头开始
        reset_state: 保留参数，始终重置状态
    """
    pipeline = K8sDeployPipeline(workflow_type="install")
    pipeline.register_all_default_stages()

    # 每次安装都删除旧状态文件，全新开始
    from src.constants import Paths
    state_file = os.path.join(PROJECT_ROOT, Paths.STATE_FILE)
    if os.path.exists(state_file):
        os.remove(state_file)
        logger.info("已重置部署状态，全新安装")

    success = pipeline.run(start_stage=start_stage)

    if success:
        logger.info("\n" + "=" * 60)
        logger.info("  K8s 集群部署成功！")
        logger.info("  请使用以下命令验证集群:")
        logger.info("    kubectl get nodes")
        logger.info("    kubectl get pods -A")
        logger.info("=" * 60)
    else:
        # 确定日志文件路径
        import datetime
        log_dir = os.path.join(PROJECT_ROOT, "runtime", "global_logs")
        log_file = os.path.join(log_dir, f"testops_{datetime.datetime.now().strftime('%Y%m%d')}.log")
        logger.error("\n" + "=" * 60)
        logger.error("  K8s 集群部署失败！")
        logger.error(f"  日志文件: {log_file}")
        logger.error(f"  状态文件: pkg_deploy/k8s_cluster/runtime/workflow.state")
        logger.error(f"  从失败点恢复: python module_main.py install --stage <N>")
        logger.error("=" * 60)
        sys.exit(1)
