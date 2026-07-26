"""
工作流状态持久化管理基类。

提供：
- 工作流状态文件的读写
- 阶段状态追踪（pending/running/success/failed/skipped）
- 断点续跑支持
- 状态历史记录
"""

import os
import time
from enum import Enum
from typing import Any, Dict, List, Optional

from common.yaml_helper import YAMLHelper
from common.logger import get_logger

logger = get_logger(__name__)


class StageStatus(Enum):
    """阶段执行状态。"""
    PENDING = "pending"
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"
    ROLLED_BACK = "rolled_back"


class StageRecord:
    """单个阶段的执行记录。"""

    def __init__(self, stage_name: str):
        self.stage_name = stage_name
        self.status: StageStatus = StageStatus.PENDING
        self.start_time: Optional[float] = None
        self.end_time: Optional[float] = None
        self.error: Optional[str] = None
        self.output: Dict[str, Any] = {}

    def to_dict(self) -> Dict:
        return {
            "stage_name": self.stage_name,
            "status": self.status.value,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "error": self.error,
            "output": self.output,
        }

    @classmethod
    def from_dict(cls, data: Dict) -> "StageRecord":
        record = cls(data["stage_name"])
        record.status = StageStatus(data.get("status", "pending"))
        record.start_time = data.get("start_time")
        record.end_time = data.get("end_time")
        record.error = data.get("error")
        record.output = data.get("output", {})
        return record


class WorkflowStateManager:
    """
    工作流状态管理器。

    用法:
        wf = WorkflowStateManager("/path/to/runtime/workflow.state")
        wf.load()

        # 标记阶段开始
        wf.start_stage("stage0_pre_check")

        # 标记阶段成功
        wf.complete_stage("stage0_pre_check", output={"nodes": 5})

        # 标记阶段失败
        wf.fail_stage("stage2_containerd_setup", error="安装失败")

        wf.save()
    """

    def __init__(self, state_file: str):
        """
        Args:
            state_file: 状态文件路径（如 runtime/workflow.state）
        """
        self.state_file = state_file
        self.component_name: str = ""
        self.workflow_type: str = ""          # install | uninstall | check | backup | upgrade
        self.created_at: Optional[float] = None
        self.updated_at: Optional[float] = None
        self.stages: List[StageRecord] = []
        self.global_data: Dict[str, Any] = {}

    # ----- 文件读写 -----

    def load(self) -> "WorkflowStateManager":
        """从文件加载状态。文件不存在则初始化为空。"""
        data = YAMLHelper.load(self.state_file, raise_on_missing=False)
        if data:
            self.component_name = data.get("component_name", "")
            self.workflow_type = data.get("workflow_type", "")
            self.created_at = data.get("created_at")
            self.updated_at = data.get("updated_at")
            self.global_data = data.get("global_data", {})
            self.stages = [
                StageRecord.from_dict(s) for s in data.get("stages", [])
            ]
            # 汇总当前各阶段状态
            status_summary = ", ".join(
                f"{s.stage_name}=[{s.status.value}]" for s in self.stages
            ) if self.stages else "(无已注册阶段)"
            logger.info(f"📂 已加载工作流状态: {self.state_file}")
            logger.info(f"   工作流类型: {self.workflow_type}, 阶段状态: {status_summary}")
        else:
            logger.info(f"📄 状态文件不存在，初始化新状态: {self.state_file}")
        return self

    def save(self) -> None:
        """保存状态到文件。"""
        now = time.time()
        self.updated_at = now
        if not self.created_at:
            self.created_at = now
        # 确保 updated_at >= created_at（修复浮点精度导致的时间倒序问题）
        if self.updated_at < self.created_at:
            self.updated_at = self.created_at
        data = {
            "component_name": self.component_name,
            "workflow_type": self.workflow_type,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "global_data": self.global_data,
            "stages": [s.to_dict() for s in self.stages],
        }
        os.makedirs(os.path.dirname(self.state_file), exist_ok=True)
        YAMLHelper.save(self.state_file, data)
        logger.debug(f"保存工作流状态: {self.state_file}")

    # ----- 阶段管理 -----

    def register_stages(self, stage_names: List[str]) -> None:
        """注册所有阶段（通常在流水线开始前调用）。"""
        existing = {s.stage_name for s in self.stages}
        for name in stage_names:
            if name not in existing:
                self.stages.append(StageRecord(name))
        logger.debug(f"注册阶段: {stage_names}")

    def get_stage(self, stage_name: str) -> Optional[StageRecord]:
        """根据名称获取阶段记录。"""
        for s in self.stages:
            if s.stage_name == stage_name:
                return s
        return None

    def start_stage(self, stage_name: str) -> StageRecord:
        """标记阶段开始执行。"""
        record = self.get_stage(stage_name)
        if record is None:
            record = StageRecord(stage_name)
            self.stages.append(record)
        record.status = StageStatus.RUNNING
        record.start_time = time.time()
        self.save()
        logger.info(f"阶段开始: {stage_name}")
        return record

    def complete_stage(self, stage_name: str, output: Dict = None) -> StageRecord:
        """标记阶段执行成功。"""
        record = self.get_stage(stage_name)
        if record is None:
            record = StageRecord(stage_name)
            self.stages.append(record)
        record.status = StageStatus.SUCCESS
        record.end_time = time.time()
        if output:
            record.output.update(output)
        self.save()
        logger.info(f"阶段完成: {stage_name}")
        return record

    def fail_stage(self, stage_name: str, error: str = "") -> StageRecord:
        """标记阶段执行失败。"""
        record = self.get_stage(stage_name)
        if record is None:
            record = StageRecord(stage_name)
            self.stages.append(record)
        record.status = StageStatus.FAILED
        record.end_time = time.time()
        record.error = error
        self.save()
        logger.error(f"阶段失败: {stage_name} — {error}")
        return record

    def skip_stage(self, stage_name: str, reason: str = "") -> StageRecord:
        """标记阶段被跳过。"""
        record = self.get_stage(stage_name)
        if record is None:
            record = StageRecord(stage_name)
            self.stages.append(record)
        record.status = StageStatus.SKIPPED
        record.output["skip_reason"] = reason
        self.save()
        logger.info(f"阶段跳过: {stage_name} — {reason}")
        return record

    def rollback_stage(self, stage_name: str) -> StageRecord:
        """标记阶段已回滚。"""
        record = self.get_stage(stage_name)
        if record is None:
            record = StageRecord(stage_name)
            self.stages.append(record)
        record.status = StageStatus.ROLLED_BACK
        self.save()
        logger.info(f"阶段已回滚: {stage_name}")
        return record

    # ----- 断点续跑 -----

    def get_last_successful_stage(self) -> Optional[str]:
        """获取最后一个成功的阶段名称（用于断点续跑）。"""
        for stage in reversed(self.stages):
            if stage.status == StageStatus.SUCCESS:
                return stage.stage_name
        return None

    def get_first_pending_stage(self) -> Optional[str]:
        """获取第一个待执行的阶段名称。"""
        for stage in self.stages:
            if stage.status in (StageStatus.PENDING, StageStatus.FAILED):
                return stage.stage_name
        return None

    def is_stage_completed(self, stage_name: str) -> bool:
        """检查指定阶段是否已成功完成。"""
        record = self.get_stage(stage_name)
        return record is not None and record.status == StageStatus.SUCCESS

    def require_stage_success(self, stage_name: str) -> dict:
        """
        要求前置阶段必须已成功完成，否则抛出异常。
        同时返回该阶段的 global_data 供后续阶段使用。

        用法:
            pre_check_data = state.require_stage_success("stage0_pre_check")
            # pre_check_data 包含 stage0 存入 global_data 的所有数据
        """
        self.load()
        record = self.get_stage(stage_name)
        if record is None or record.status != StageStatus.SUCCESS:
            raise RuntimeError(
                f"前置阶段 {stage_name} 未成功完成（当前状态: {record.status.value if record else 'unknown'}），"
                f"请先执行该阶段后再继续"
            )
        logger.info(f"✓ 前置阶段校验通过: {stage_name}")
        return self.global_data

    def reset_from_stage(self, stage_name: str) -> None:
        """
        从指定阶段开始重置（将该阶段及之后的所有阶段重置为 PENDING）。
        用于断点续跑时清理后续阶段状态。
        """
        reset_stages = []
        reset = False
        for stage in self.stages:
            if stage.stage_name == stage_name:
                reset = True
            if reset:
                stage.status = StageStatus.PENDING
                stage.start_time = None
                stage.end_time = None
                stage.error = None
                reset_stages.append(stage.stage_name)
        if reset_stages:
            logger.info(f"🔄 重置阶段状态 → PENDING: {', '.join(reset_stages)}")
        else:
            logger.warning(f"⚠ 未找到阶段 '{stage_name}'，跳过重置")
        self.save()

    # ----- 全局数据存取 -----

    def set_global(self, key: str, value: Any) -> None:
        """设置全局共享数据（跨阶段传递，如 join token）。"""
        self.global_data[key] = value

    def get_global(self, key: str, default: Any = None) -> Any:
        """获取全局共享数据。"""
        return self.global_data.get(key, default)

    # ----- 统计信息 -----

    def get_progress(self) -> Dict[str, int]:
        """获取执行进度统计。"""
        counts = {s.value: 0 for s in StageStatus}
        for stage in self.stages:
            counts[stage.status.value] += 1
        total = len(self.stages)
        completed = counts["success"] + counts["skipped"]
        return {
            "total": total,
            "completed": completed,
            "percent": round(completed / total * 100, 1) if total > 0 else 0,
            **counts,
        }

    def get_summary(self) -> str:
        """生成可读的状态摘要。"""
        lines = [
            f"组件: {self.component_name}",
            f"工作流: {self.workflow_type}",
            f"进度: {self.get_progress()['percent']}%",
            "-" * 40,
        ]
        for stage in self.stages:
            icon = {
                StageStatus.SUCCESS: "✓",
                StageStatus.FAILED: "✗",
                StageStatus.RUNNING: "▶",
                StageStatus.SKIPPED: "→",
                StageStatus.ROLLED_BACK: "↩",
                StageStatus.PENDING: "○",
            }.get(stage.status, "?")
            lines.append(f"  {icon} {stage.stage_name} [{stage.status.value}]")
        return "\n".join(lines)
