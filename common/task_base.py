"""
所有任务的父类 — 统一钩子、异常捕获、日志标准。

每个部署组件的安装、卸载、检查、备份等任务都应继承此基类，
从而获得统一的生命周期管理、日志记录和错误处理能力。
"""

import time
import traceback
from abc import ABC, abstractmethod
from enum import Enum
from typing import Any, Dict, Optional

from common.logger import get_logger
from common.exceptions import TestOpsException


class TaskStatus(Enum):
    """任务执行状态枚举。"""
    PENDING = "pending"
    RUNNING = "running"
    SUCCESS = "success"
    FAILED = "failed"
    SKIPPED = "skipped"
    ROLLED_BACK = "rolled_back"


class TaskResult:
    """任务执行结果。"""

    def __init__(self, task_name: str):
        self.task_name = task_name
        self.status = TaskStatus.PENDING
        self.start_time: Optional[float] = None
        self.end_time: Optional[float] = None
        self.elapsed_seconds: float = 0.0
        self.error: Optional[Exception] = None
        self.data: Dict[str, Any] = {}
        self.messages: list = []

    @property
    def is_success(self) -> bool:
        return self.status == TaskStatus.SUCCESS

    @property
    def is_failed(self) -> bool:
        return self.status == TaskStatus.FAILED

    def to_dict(self) -> Dict:
        return {
            "task_name": self.task_name,
            "status": self.status.value,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "elapsed_seconds": self.elapsed_seconds,
            "error": str(self.error) if self.error else None,
            "data": self.data,
            "messages": self.messages,
        }

    def __repr__(self):
        return (
            f"TaskResult({self.task_name}, status={self.status.value}, "
            f"elapsed={self.elapsed_seconds:.1f}s)"
        )


class BaseTask(ABC):
    """
    所有任务的抽象父类。

    子类必须实现:
        - _execute(): 核心执行逻辑
        - _rollback(): 失败回滚逻辑

    生命周期钩子（可选重写）:
        - _pre_execute(): 执行前预处理
        - _post_execute(): 执行后收尾（无论成功与否都执行）
        - _on_success(): 成功后回调
        - _on_error(): 失败后回调

    用法:
        class MyTask(BaseTask):
            def _execute(self):
                # 核心逻辑
                pass

            def _rollback(self):
                # 回滚逻辑
                pass

        task = MyTask(name="my_task")
        result = task.run()
    """

    def __init__(self, name: str = None, logger_name: str = None):
        """
        Args:
            name: 任务名称（默认使用类名）
            logger_name: logger 名称
        """
        self.name = name or self.__class__.__name__
        self.logger = get_logger(logger_name or self.name)
        self.result = TaskResult(self.name)
        self._context: Dict[str, Any] = {}

    # ----- 抽象方法（子类必须实现） -----

    @abstractmethod
    def _execute(self) -> None:
        """核心业务逻辑。子类在此实现具体的部署/检查/备份等操作。"""

    @abstractmethod
    def _rollback(self) -> None:
        """
        失败回滚逻辑。

        注意：此方法应尽量幂等，允许多次调用不产生副作用。
        如果回滚本身也失败，记录日志但不应再抛出异常。
        """

    # ----- 钩子方法（子类可选重写） -----

    def _pre_execute(self) -> None:
        """执行前钩子：参数校验、环境准备等。"""
        pass

    def _post_execute(self) -> None:
        """执行后钩子：资源清理、临时文件删除等。无论成功与否都执行。"""
        pass

    def _on_success(self) -> None:
        """成功回调：记录成功信息、发送通知等。"""
        pass

    def _on_error(self, error: Exception) -> None:
        """失败回调：记录错误详情、发送告警等。"""
        pass

    # ----- 上下文管理 -----

    def set_context(self, key: str, value: Any) -> None:
        """设置任务上下文数据（跨阶段传递）。"""
        self._context[key] = value

    def get_context(self, key: str, default: Any = None) -> Any:
        """获取任务上下文数据。"""
        return self._context.get(key, default)

    # ----- 执行入口 -----

    def run(self, **kwargs) -> TaskResult:
        """
        任务主执行方法。

        执行流程:
            1. _pre_execute() — 预处理钩子
            2. _execute()     — 核心逻辑
            3. _on_success()  — 成功回调
            --- 如果失败 ---
            4. _rollback()    — 回滚
            5. _on_error()    — 错误回调
            --- 无论如何 ---
            6. _post_execute() — 收尾钩子

        Returns:
            TaskResult 实例
        """
        self.result.status = TaskStatus.RUNNING
        self.result.start_time = time.time()

        try:
            self.logger.info(f"[{self.name}] ========== 任务开始 ==========")

            # 1. 预处理
            self._pre_execute()

            # 2. 核心逻辑
            self._execute()

            # 3. 成功
            self.result.status = TaskStatus.SUCCESS
            self.result.end_time = time.time()
            self.result.elapsed_seconds = (
                self.result.end_time - self.result.start_time
            )
            self._on_success()
            self.logger.info(
                f"[{self.name}] 任务完成 ✓ (耗时 {self.result.elapsed_seconds:.1f}s)"
            )

        except TestOpsException as e:
            self._handle_error(e)

        except Exception as e:
            self._handle_error(e)

        finally:
            # 6. 收尾清理
            try:
                self._post_execute()
            except Exception as post_error:
                self.logger.warning(
                    f"[{self.name}] 收尾清理异常: {post_error}"
                )

        return self.result

    def _handle_error(self, error: Exception) -> None:
        """统一错误处理。"""
        self.result.status = TaskStatus.FAILED
        self.result.end_time = time.time()
        self.result.elapsed_seconds = (
            self.result.end_time - self.result.start_time
        )
        self.result.error = error

        self.logger.error(
            f"[{self.name}] 任务失败 ✗ — {error}\n"
            f"{traceback.format_exc()}"
        )

        # 回滚
        try:
            self.logger.info(f"[{self.name}] 开始回滚...")
            self._rollback()
            self.result.status = TaskStatus.ROLLED_BACK
            self.logger.info(f"[{self.name}] 回滚完成")
        except Exception as rollback_error:
            self.logger.error(
                f"[{self.name}] 回滚也失败了: {rollback_error}"
            )

        # 错误回调
        try:
            self._on_error(error)
        except Exception as cb_error:
            self.logger.warning(f"[{self.name}] on_error 回调异常: {cb_error}")

    def __repr__(self):
        return f"{self.__class__.__name__}(name={self.name})"
