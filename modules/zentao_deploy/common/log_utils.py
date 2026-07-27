"""
统一日志管理组件
所有模块共享，输出至控制台 + 文件
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

LOG_LEVELS = {
    "DEBUG": logging.DEBUG, "INFO": logging.INFO, "WARNING": logging.WARNING,
    "ERROR": logging.ERROR, "CRITICAL": logging.CRITICAL,
}
COLOR_FORMAT = "%(log_color)s%(asctime)s | %(levelname)-8s | %(name)s | %(message)s%(reset)s"
PLAIN_FORMAT = "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
COLOR_MAP = {"DEBUG": "cyan", "INFO": "green", "WARNING": "yellow", "ERROR": "red", "CRITICAL": "red,bg_white"}


class _SafeUTF8StreamHandler(logging.StreamHandler):
    """Windows GBK 终端下安全输出 UTF-8"""

    def emit(self, record: logging.LogRecord) -> None:
        try:
            msg = self.format(record) + self.terminator
            stream = self.stream
            if hasattr(stream, 'buffer') and stream.buffer is not None:
                try:
                    stream.buffer.write(msg.encode('utf-8', errors='replace'))
                    stream.buffer.flush()
                    return
                except Exception:
                    pass
            stream.write(msg)
        except Exception:
            self.handleError(record)


def get_logger(name: str, level: str = "INFO", log_dir: str = None) -> logging.Logger:
    """获取配置好的 logger 实例"""
    logger = logging.getLogger(name)
    logger.setLevel(LOG_LEVELS.get(level.upper(), logging.INFO))
    if logger.handlers:
        return logger

    datefmt = "%Y-%m-%d %H:%M:%S"
    # 控制台
    ch = _SafeUTF8StreamHandler(sys.stdout)
    if HAS_COLORLOG:
        ch.setFormatter(colorlog.ColoredFormatter(COLOR_FORMAT, datefmt=datefmt, log_colors=COLOR_MAP))
    else:
        ch.setFormatter(logging.Formatter(PLAIN_FORMAT, datefmt=datefmt))
    logger.addHandler(ch)
    # 文件
    if log_dir is None:
        log_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs")
    os.makedirs(log_dir, exist_ok=True)
    fh = RotatingFileHandler(
        os.path.join(log_dir, f"zentao_deploy_{datetime.now().strftime('%Y%m%d')}.log"),
        maxBytes=10 * 1024 * 1024, backupCount=7, encoding="utf-8"
    )
    fh.setFormatter(logging.Formatter(PLAIN_FORMAT, datefmt=datefmt))
    logger.addHandler(fh)
    return logger


def setup_stdout_encoding():
    """确保 Windows 终端支持 UTF-8 输出"""
    for sn in ('stdout', 'stderr'):
        stream = getattr(sys, sn, None)
        if stream is None:
            continue
        try:
            if hasattr(stream, 'buffer') and stream.buffer is not None:
                setattr(sys, sn, io.TextIOWrapper(
                    stream.buffer, encoding='utf-8', errors='replace', line_buffering=True))
        except Exception:
            pass
