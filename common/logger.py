"""
统一日志管理器。

特性：
- 同时输出到控制台和文件
- 支持按模块/组件分级控制日志级别
- 彩色控制台输出（colorlog）
- 自动按日滚动日志文件
- 运行时动态调整日志级别
"""

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

    # 控制台 handler
    if log_to_console:
        console_handler = logging.StreamHandler(sys.stdout)
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
