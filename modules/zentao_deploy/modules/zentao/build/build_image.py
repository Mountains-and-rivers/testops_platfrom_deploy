"""
禅道源码拉取、镜像构建、打Tag、推送 Harbor
用法: python build_image.py [--version 21.2] [--push]
"""

import os
import sys
import subprocess
import argparse

# 将项目根目录加入 sys.path
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.log_utils import get_logger, setup_stdout_encoding
from common.yaml_render import YAMLHelper
from common.ssh_client import SSHClient
from common.harbor_client import HarborClient
from common.pre_check import run_pre_check

setup_stdout_encoding()
logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "configs")
MODULE_DIR = os.path.dirname(__file__)
SOURCE_DIR = os.path.join(MODULE_DIR, "source")


def clone_source(version: str, ssh: SSHClient = None):
    """拉取禅道源码到本地 source/ 目录"""
    logger.info(f"拉取禅道开源版 v{version} 源码...")
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    source_url = config.get("zentao", {}).get("source_url", "https://github.com/easysoft/zentaopms")
    mirror_url = config.get("zentao", {}).get("source_mirror", "https://gitee.com/easysoft/zentaopms")

    # 清理旧源码
    if os.path.exists(SOURCE_DIR):
        import shutil
        shutil.rmtree(SOURCE_DIR)
    os.makedirs(SOURCE_DIR, exist_ok=True)

    # 尝试从 GitHub 拉取，失败则用 Gitee 镜像
    for url in [source_url, mirror_url]:
        try:
            logger.info(f"  尝试: {url}")
            subprocess.run(
                ["git", "clone", "--depth", "1", "--branch", version, url, SOURCE_DIR],
                check=True, capture_output=True, text=True, timeout=120
            )
            logger.info(f"  源码拉取成功: {SOURCE_DIR}")
            return
        except subprocess.CalledProcessError:
            logger.warning(f"  拉取失败，尝试下一个源...")

    raise RuntimeError(f"无法拉取禅道 v{version} 源码")


def build_image(version: str, registry: str, project: str, push: bool = False):
    """构建 Docker 镜像"""
    logger.info(f"构建禅道镜像 v{version}...")
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    image_name = config.get("harbor", {}).get("image_name", "zentao")
    full_image = f"{registry}/{project}/{image_name}:{version}"

    # 1. 拉取源码
    if not os.path.exists(os.path.join(SOURCE_DIR, "www")):
        clone_source(version)

    # 2. 构建镜像
    logger.info("  Docker build (多阶段编译，约 5-15 分钟)...")
    result = subprocess.run(
        ["docker", "build", "--build-arg", f"ZENTAO_VERSION={version}",
         "-t", full_image, "-t", f"{registry}/{project}/{image_name}:latest",
         "-f", os.path.join(MODULE_DIR, "Dockerfile"), MODULE_DIR],
        capture_output=False, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"Docker 构建失败: exit_code={result.returncode}")
    logger.info(f"  镜像构建完成: {full_image}")

    # 3. 本地验证
    logger.info("  本地验证容器启动...")
    subprocess.run(
        ["docker", "rm", "-f", "zentao-verify"], capture_output=True
    )
    verify_result = subprocess.run(
        ["docker", "run", "-d", "--name", "zentao-verify", "-p", "18080:8080",
         "-e", "ZT_MYSQL_HOST=host.docker.internal",
         "-e", "ZT_MYSQL_PORT=3306",
         "-e", "ZT_MYSQL_USER=root",
         "-e", "ZT_MYSQL_PASSWORD=test",
         "-e", "ZT_MYSQL_DB=zentao",
         full_image],
        capture_output=True, text=True, timeout=30
    )
    if verify_result.returncode != 0:
        logger.warning(f"  本地验证失败: {verify_result.stderr[:200]}")
    else:
        logger.info("  本地验证容器已启动")
        subprocess.run(["docker", "rm", "-f", "zentao-verify"], capture_output=True)

    # 4. 推送
    if push:
        logger.info(f"  推送镜像到 {full_image}...")
        push_result = subprocess.run(
            ["docker", "push", full_image], capture_output=False, text=True
        )
        latest_result = subprocess.run(
            ["docker", "push", f"{registry}/{project}/{image_name}:latest"],
            capture_output=False, text=True
        )
        if push_result.returncode == 0 and latest_result.returncode == 0:
            logger.info("  推送完成")
        else:
            raise RuntimeError("镜像推送失败")

    return full_image


def main():
    parser = argparse.ArgumentParser(description="禅道镜像构建工具")
    parser.add_argument("--version", default="21.2", help="禅道版本号")
    parser.add_argument("--push", action="store_true", help="构建后推送到 Harbor")
    parser.add_argument("--skip-pull", action="store_true", help="跳过源码拉取")
    args = parser.parse_args()

    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    registry = config.get("harbor", {}).get("url", "").replace("https://", "").replace("http://", "")
    project = config.get("harbor", {}).get("project", "testops")

    if not args.skip_pull:
        clone_source(args.version)

    image = build_image(args.version, registry, project, push=args.push)

    logger.info(f"\n{'='*50}")
    logger.info(f"  镜像构建完成: {image}")
    if not args.push:
        logger.info(f"  下一步: python build_image.py --push")
    logger.info(f"{'='*50}")


if __name__ == "__main__":
    main()
