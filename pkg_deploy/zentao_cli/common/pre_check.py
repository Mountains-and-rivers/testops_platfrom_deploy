"""
全局环境预检模块
检查：磁盘空间、网络连通、Docker 可用性、必要命令
"""

import os
import sys
import shutil
import socket
import subprocess
from common.log_utils import get_logger

logger = get_logger(__name__)

REQUIRED_COMMANDS = ["docker", "git", "wget", "curl", "kubectl", "python3"]
REQUIRED_DISK_GB = 10


def check_command(cmd: str) -> bool:
    """检查命令是否可用"""
    path = shutil.which(cmd)
    if path:
        logger.debug(f"  ✓ {cmd}: {path}")
        return True
    logger.error(f"  ✗ {cmd}: 未安装")
    return False


def check_disk_space(path: str = "/tmp", required_gb: int = REQUIRED_DISK_GB) -> bool:
    """检查磁盘空间"""
    try:
        stat = os.statvfs(path)
        free_gb = (stat.f_frsize * stat.f_bavail) / (1024 ** 3)
        if free_gb >= required_gb:
            logger.info(f"  磁盘空间: {free_gb:.1f} GB (需 ≥ {required_gb} GB)")
            return True
        logger.error(f"  磁盘空间不足: {free_gb:.1f} GB < {required_gb} GB")
        return False
    except Exception as e:
        logger.warning(f"无法检查磁盘空间: {e}")
        return True


def check_network(host: str = "harbor.testops.local", port: int = 443) -> bool:
    """检查网络连通性"""
    try:
        sock = socket.create_connection((host, port), timeout=5)
        sock.close()
        logger.info(f"  网络连通: {host}:{port}")
        return True
    except Exception:
        logger.warning(f"  网络不通: {host}:{port}（可能影响镜像推送）")
        return False


def check_docker() -> bool:
    """检查 Docker 是否可用"""
    try:
        result = subprocess.run(["docker", "info"], capture_output=True, text=True, timeout=15)
        if result.returncode == 0:
            logger.info("  Docker: 可用")
            return True
        logger.error(f"  Docker: 不可用 — {result.stderr[:100]}")
        return False
    except Exception as e:
        logger.error(f"  Docker: 异常 — {e}")
        return False


def run_pre_check(config: dict = None) -> bool:
    """执行完整预检，返回 True/False"""
    logger.info("=" * 50)
    logger.info("环境预检开始")
    logger.info("=" * 50)

    all_ok = True

    # 必要命令
    logger.info("[1/4] 必要命令检查...")
    for cmd in REQUIRED_COMMANDS:
        if not check_command(cmd):
            all_ok = False

    # 磁盘空间
    logger.info("[2/4] 磁盘空间检查...")
    if not check_disk_space():
        all_ok = False

    # Docker
    logger.info("[3/4] Docker 检查...")
    if not check_docker():
        all_ok = False

    # Harbor 连通性
    logger.info("[4/4] Harbor 连通性...")
    if config:
        harbor_url = config.get("harbor", {}).get("url", "")
        if harbor_url:
            host = harbor_url.replace("https://", "").replace("http://", "").split("/")[0]
            check_network(host, 443)

    logger.info("=" * 50)
    if all_ok:
        logger.info("预检通过")
    else:
        logger.error("预检未通过，请修复上述问题后重试")
    logger.info("=" * 50)
    return all_ok
