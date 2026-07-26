"""
统一日志管理器。

特性：
- 同时输出到控制台和文件
- 支持按模块/组件分级控制日志级别
- 彩色控制台输出（colorlog）
- 自动按日滚动日志文件
- 运行时动态调整日志级别
- Windows GBK 终端下自动适配 UTF-8 输出（UnicodeEncodeError 容错）
"""

import io
import os
import sys
import logging
from logging.handlers import RotatingFileHandler
from datetime import datetime

try:
    import colorlog
    HAS_COLORLOG = True
except ImportError:
    HAS_COLORLOG = False

# 全局日志级别映射
LOG_LEVELS = {
    "DEBUG": logging.DEBUG,
    "INFO": logging.INFO,
    "WARNING": logging.WARNING,
    "ERROR": logging.ERROR,
    "CRITICAL": logging.CRITICAL,
}

# 默认日志格式
CONSOLE_FORMAT = "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
FILE_FORMAT = "%(asctime)s | %(levelname)-8s | %(name)s | %(filename)s:%(lineno)d | %(message)s"

# 彩色控制台格式
COLOR_FORMAT = (
    "%(log_color)s%(asctime)s | %(levelname)-8s | %(name)s | %(message)s%(reset)s"
)

COLOR_MAP = {
    "DEBUG": "cyan",
    "INFO": "green",
    "WARNING": "yellow",
    "ERROR": "red",
    "CRITICAL": "red,bg_white",
}


class _SafeUTF8StreamHandler(logging.StreamHandler):
    """
    安全的 UTF-8 StreamHandler。

    在 Windows GBK 终端下，直接写入 sys.stdout 会因无法编码 emoji / Unicode
    特殊字符而抛出 UnicodeEncodeError。此 handler 绕过 Python 文本层的编码
    限制，直接写入底层 buffer（UTF-8 字节），兼容中英文混输场景。
    """

    def emit(self, record: logging.LogRecord) -> None:
        try:
            msg = self.format(record) + self.terminator
            stream = self.stream
            # 优先写入底层二进制 buffer（绕过 GBK 编码限制）
            if hasattr(stream, 'buffer') and stream.buffer is not None:
                try:
                    stream.buffer.write(msg.encode('utf-8', errors='replace'))
                    stream.buffer.flush()
                    return
                except Exception:
                    pass
            # 回退：直接写入文本流（Unix / UTF-8 终端走这里）
            stream.write(msg)
        except Exception:
            self.handleError(record)


def get_logger(
    name: str,
    level: str = "INFO",
    log_dir: str = None,
    log_to_console: bool = True,
    log_to_file: bool = True,
) -> logging.Logger:
    """
    获取一个配置好的 logger 实例。

    Args:
        name: logger 名称（通常传 __name__）
        level: 日志级别，默认 INFO
        log_dir: 日志文件目录，默认从环境变量 TESTOPS_LOG_DIR 读取，
                 最终回退到 ./runtime/global_logs/
        log_to_console: 是否输出到控制台
        log_to_file: 是否输出到文件

    Returns:
        配置好的 logging.Logger 实例
    """
    logger = logging.getLogger(name)
    logger.setLevel(LOG_LEVELS.get(level.upper(), logging.INFO))

    # 避免重复添加 handler
    if logger.handlers:
        return logger

    datefmt = "%Y-%m-%d %H:%M:%S"

    # 控制台 handler（使用 UTF-8 安全 handler）
    if log_to_console:
        console_handler = _SafeUTF8StreamHandler(sys.stdout)
        if HAS_COLORLOG:
            console_formatter = colorlog.ColoredFormatter(
                COLOR_FORMAT,
                datefmt=datefmt,
                log_colors=COLOR_MAP,
            )
        else:
            console_formatter = logging.Formatter(CONSOLE_FORMAT, datefmt=datefmt)
        console_handler.setFormatter(console_formatter)
        logger.addHandler(console_handler)

    # 文件 handler
    if log_to_file:
        if log_dir is None:
            log_dir = os.environ.get("TESTOPS_LOG_DIR", "")
        if not log_dir:
            # 回退到项目 runtime/global_logs/
            project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            log_dir = os.path.join(project_root, "runtime", "global_logs")

        os.makedirs(log_dir, exist_ok=True)
        log_file = os.path.join(
            log_dir,
            f"testops_{datetime.now().strftime('%Y%m%d')}.log"
        )
        file_handler = RotatingFileHandler(
            log_file,
            maxBytes=10 * 1024 * 1024,  # 10 MB
            backupCount=7,
            encoding="utf-8",
        )
        file_formatter = logging.Formatter(FILE_FORMAT, datefmt=datefmt)
        file_handler.setFormatter(file_formatter)
        logger.addHandler(file_handler)

    return logger


def set_global_log_level(level: str):
    """动态调整全局日志级别。"""
    log_level = LOG_LEVELS.get(level.upper(), logging.INFO)
    logging.root.setLevel(log_level)
    for handler in logging.root.handlers:
        handler.setLevel(log_level)


def setup_stdout_encoding():
    """
    确保 stdout / stderr 支持 UTF-8 输出。

    在 Windows 系统上，Python 默认使用 GBK 编码输出到控制台，导致
    emoji 和 Unicode 特殊字符（✓ ✗ ✅ ❌ 📂 🔄 等）抛出
    UnicodeEncodeError。此函数将 stdout / stderr 重新包装为 UTF-8。

    应在所有入口模块的最顶部（import 之后）调用一次。
    """
    for stream_name in ('stdout', 'stderr'):
        stream = getattr(sys, stream_name, None)
        if stream is None:
            continue
        try:
            if hasattr(stream, 'buffer') and stream.buffer is not None:
                setattr(sys, stream_name,
                        io.TextIOWrapper(stream.buffer,
                                         encoding='utf-8',
                                         errors='replace',
                                         line_buffering=True))
        except Exception:
            # 如果已经包装过或 buffer 不可用，静默跳过
            pass
