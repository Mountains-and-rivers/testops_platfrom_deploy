"""
K8s Cluster Deploy — 工作流流水线调度器

负责按顺序调度 8 个部署阶段，支持：
- 阶段依赖检查
- 失败自动停止
- 断点续跑（从指定阶段开始）
- 状态持久化
"""

import os
import sys
from typing import Dict, List, Optional, Callable

# 确保项目根目录在 path 中
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.workflow_state import WorkflowStateManager, StageStatus
from common.yaml_helper import YAMLHelper
from src.constants import DeployStage, Paths
from src.workflow.workflow_exception import K8sStageError

logger = get_logger(__name__)

# workflow 定义文件路径
WORKFLOW_CONFIG_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "config"
)


class K8sDeployPipeline:
    """
    K8s 集群部署流水线调度器。

    用法:
        pipeline = K8sDeployPipeline()
        pipeline.register_stage("stage0_pre_check", run_pre_check)
        pipeline.register_stage("stage1_sys_init", run_sys_init)
        ...
        pipeline.run(start_stage=0)
    """

    def __init__(self, component_name: str = "k8s_cluster",
                 workflow_type: str = "install"):
        self.component_name = component_name
        self.workflow_type = workflow_type

        # 状态管理器
        state_file = os.path.join(PROJECT_ROOT, Paths.STATE_FILE)
        self.state = WorkflowStateManager(state_file)
        self.state.component_name = component_name
        self.state.workflow_type = workflow_type

        # 阶段注册表：{stage_name: callable}
        self._stages: Dict[str, Callable] = {}
        # 回滚函数注册表：{stage_name: callable}
        self._rollbacks: Dict[str, Callable] = {}
        # 阶段顺序
        self._stage_order: List[str] = []

        # 工作流配置（从 config/workflow.yaml 读取）
        self._workflow_config: Dict = {}
        self._load_workflow_config()

    def _load_workflow_config(self) -> None:
        """加载工作流配置文件 config/workflow.yaml。"""
        wf_file = os.path.join(WORKFLOW_CONFIG_DIR, "workflow.yaml")
        self._workflow_config = YAMLHelper.load(wf_file, raise_on_missing=False) or {}
        if self._workflow_config:
            logger.debug(f"已加载工作流配置: {wf_file}")

    def is_stage_enabled(self, stage_name: str) -> bool:
        """
        检查指定阶段是否启用（从 workflow.yaml 读取 enabled 字段）。
        如果 workflow.yaml 中没有定义，默认启用。
        """
        stages = self._workflow_config.get("workflow", {}).get("stages", [])
        for s in stages:
            if s.get("name") == stage_name:
                return s.get("enabled", True)
        return True  # 未定义时默认启用

    def register_stage(self, name: str, handler: Callable,
                       rollback: Callable = None) -> None:
        """
        注册一个阶段处理函数。

        Args:
            name: 阶段名称（如 "stage0_pre_check"）
            handler: 阶段执行函数，签名为 handler(state: WorkflowStateManager) -> None
            rollback: 阶段回滚函数，签名为 rollback(state: WorkflowStateManager) -> None
        """
        self._stages[name] = handler
        self._stage_order.append(name)
        if rollback:
            self._rollbacks[name] = rollback

    def register_all_default_stages(self) -> None:
        """自动注册所有默认部署阶段及回滚函数。"""
        # 延迟导入避免循环依赖
        from src.stages.stage0_pre_check import run_pre_check
        from src.stages.stage1_sys_init import run_sys_init, rollback_sys_init
        from src.stages.stage2_containerd_setup import run_containerd_setup, rollback_containerd_setup
        from src.stages.stage3_kube_components import run_kube_components, rollback_kube_components
        from src.stages.stage4_master_init import run_master_init, rollback_master_init
        from src.stages.stage5_node_join import run_node_join, rollback_node_join
        from src.stages.stage6_cni_deploy import run_cni_deploy, rollback_cni_deploy
        from src.stages.stage7_cluster_verify import run_cluster_verify, rollback_cluster_verify

        stage_defs = [
            ("stage0_pre_check", run_pre_check, None),                   # 只读，无需回滚
            ("stage1_sys_init", run_sys_init, rollback_sys_init),
            ("stage2_containerd_setup", run_containerd_setup, rollback_containerd_setup),
            ("stage3_kube_components", run_kube_components, rollback_kube_components),
            ("stage4_master_init", run_master_init, rollback_master_init),
            ("stage5_node_join", run_node_join, rollback_node_join),
            ("stage6_cni_deploy", run_cni_deploy, rollback_cni_deploy),
            ("stage7_cluster_verify", run_cluster_verify, rollback_cluster_verify),
        ]
        for name, handler, rollback in stage_defs:
            self.register_stage(name, handler, rollback=rollback)

    def run(self, start_stage: int = 0, stop_stage: int = None) -> bool:
        """
        执行流水线。

        Args:
            start_stage: 起始阶段编号（0-based），支持断点续跑
            stop_stage: 终止阶段编号（含），None 表示执行到最后

        Returns:
            True 表示全部阶段执行成功，False 表示有阶段失败
        """
        # 加载历史状态
        self.state.load()
        self.state.register_stages(self._stage_order)

        if stop_stage is None:
            stop_stage = len(self._stage_order) - 1

        logger.info(f"{'='*50}")
        logger.info(f"流水线启动: {self.workflow_type}")
        logger.info(f"阶段范围: Stage {start_stage} → Stage {stop_stage}")
        logger.info(f"{'='*50}")

        for idx in range(start_stage, stop_stage + 1):
            if idx >= len(self._stage_order):
                break

            stage_name = self._stage_order[idx]

            # 检查是否已完成（支持断点续跑时跳过）
            if self.state.is_stage_completed(stage_name):
                logger.info(f"阶段已完成，跳过: {stage_name}")
                continue

            # 检查 workflow.yaml 中是否启用了此阶段
            if not self.is_stage_enabled(stage_name):
                logger.info(f"阶段已在 workflow.yaml 中禁用，跳过: {stage_name}")
                self.state.skip_stage(stage_name, "workflow.yaml 中 enabled=false")
                continue

            logger.info(f"\n{'─'*40}")
            logger.info(f"▶ 执行阶段 [{idx}]: {stage_name}")
            logger.info(f"{'─'*40}")

            try:
                # 标记开始
                self.state.start_stage(stage_name)

                # 执行阶段
                handler = self._stages[stage_name]
                handler(self.state)

                # 标记成功
                self.state.complete_stage(stage_name)
                logger.info(f"✓ 阶段完成: {stage_name}")

            except K8sStageError as e:
                self.state.fail_stage(stage_name, str(e))
                logger.error(f"✗ 阶段失败: {stage_name} — {e}")
                self._print_failure_summary(idx, stage_name)
                return False

            except Exception as e:
                self.state.fail_stage(stage_name, str(e))
                logger.error(f"✗ 阶段异常: {stage_name} — {e}")
                self._print_failure_summary(idx, stage_name)
                return False

        logger.info(f"\n{'='*50}")
        logger.info(f"流水线执行完毕: 全部阶段成功")
        logger.info(f"{'='*50}")
        return True

    def run_stage(self, stage_num: int) -> bool:
        """
        单独执行指定阶段（不执行其他阶段）。

        Args:
            stage_num: 阶段编号（0-based）

        Returns:
            True 表示执行成功，False 表示失败
        """
        if stage_num >= len(self._stage_order):
            logger.error(f"无效的阶段编号: {stage_num}，有效范围 0-{len(self._stage_order) - 1}")
            return False

        stage_name = self._stage_order[stage_num]

        # 加载状态
        self.state.load()
        self.state.register_stages(self._stage_order)

        # 检查 workflow.yaml 中是否启用了此阶段
        if not self.is_stage_enabled(stage_name):
            logger.info(f"阶段已在 workflow.yaml 中禁用，跳过: {stage_name}")
            self.state.skip_stage(stage_name, "workflow.yaml 中 enabled=false")
            return True

        logger.info(f"{'='*50}")
        logger.info(f"单阶段执行: {stage_name} (Stage {stage_num})")
        logger.info(f"{'='*50}")

        try:
            self.state.start_stage(stage_name)
            handler = self._stages.get(stage_name)
            if not handler:
                logger.error(f"未注册的阶段: {stage_name}")
                return False

            handler(self.state)
            self.state.complete_stage(stage_name)
            logger.info(f"✓ 阶段完成: {stage_name}")
            return True

        except K8sStageError as e:
            self.state.fail_stage(stage_name, str(e))
            logger.error(f"✗ 阶段失败: {stage_name} — {e}")
            return False

        except Exception as e:
            self.state.fail_stage(stage_name, str(e))
            logger.error(f"✗ 阶段异常: {stage_name} — {e}")
            return False

    def rollback_stage(self, stage_num: int) -> bool:
        """
        回滚指定阶段：卸载该阶段所做的一切更改。

        Args:
            stage_num: 阶段编号（0-based）

        Returns:
            True 表示回滚成功，False 表示失败
        """
        if stage_num >= len(self._stage_order):
            logger.error(f"无效的阶段编号: {stage_num}，有效范围 0-{len(self._stage_order) - 1}")
            return False

        stage_name = self._stage_order[stage_num]
        rollback_fn = self._rollbacks.get(stage_name)

        if not rollback_fn:
            logger.info(f"阶段 {stage_name} 无需回滚（只读操作或无回滚逻辑）")
            return True

        self.state.load()
        self.state.register_stages(self._stage_order)

        logger.info(f"{'='*50}")
        logger.info(f"回滚阶段: {stage_name} (Stage {stage_num})")
        logger.info(f"{'='*50}")

        try:
            rollback_fn(self.state)
            # 标记阶段已回滚
            self.state.rollback_stage(stage_name)
            # 将当前阶段及后续阶段重置为 PENDING，支持从当前步骤继续安装
            self.state.reset_from_stage(stage_name)
            logger.info(f"✓ 回滚完成: {stage_name}（可从 Stage {stage_num} 继续安装）")
            return True

        except Exception as e:
            logger.error(f"✗ 回滚失败: {stage_name} — {e}")
            return False

    def _print_failure_summary(self, failed_idx: int, failed_stage: str):
        """打印失败摘要。"""
        logger.info(f"\n{'='*50}")
        logger.info(f"流水线中断于 Stage {failed_idx}: {failed_stage}")
        logger.info(f"已完成阶段: {self.state.get_progress()['completed']}/{len(self._stage_order)}")
        logger.info(f"状态文件: {self.state.state_file}")
        logger.info(f"可使用以下命令从失败点恢复: ")
        logger.info(f"  python module_main.py install --stage {failed_idx}")
        logger.info(f"{'='*50}")

    def get_status_summary(self) -> str:
        """获取流水线状态摘要。"""
        self.state.load()
        return self.state.get_summary()
