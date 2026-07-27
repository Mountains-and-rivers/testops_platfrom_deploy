"""
CLI 命令通用封装
"""

import sys
from typing import Callable
from common.log_utils import get_logger

logger = get_logger(__name__)


def safe_run(func_name: str):
    """统一异常捕获装饰器，输出清晰错误信息"""
    def decorator(fn: Callable):
        import functools
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            try:
                return fn(*args, **kwargs)
            except FileNotFoundError as e:
                logger.error(f"[{func_name}] 文件未找到: {e}")
                sys.exit(1)
            except ModuleNotFoundError as e:
                logger.error(f"[{func_name}] 模块未安装: {e.name}，请 pip install -r requirements.txt")
                sys.exit(1)
            except KeyboardInterrupt:
                logger.warning(f"[{func_name}] 用户中断")
                sys.exit(130)
            except Exception as e:
                logger.error(f"[{func_name}] 执行失败: {type(e).__name__}: {e}")
                sys.exit(1)
        return wrapper
    return decorator
