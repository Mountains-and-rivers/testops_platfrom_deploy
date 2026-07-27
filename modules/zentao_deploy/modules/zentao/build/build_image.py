"""
禅道源码拉取、镜像构建、打Tag、推送 Harbor
支持远程编译服务器（SSH）和本地构建两种模式
用法: python build_image.py [--version 21.2] [--push] [--local]
"""

import os
import sys
import subprocess
import argparse

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


def _get_build_ssh():
    """获取编译服务器 SSH 连接"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    bs = config.get("build_server", {})
    if not bs.get("host"):
        return None
    ssh = SSHClient(
        host=bs["host"], username=bs.get("username", "root"),
        port=bs.get("port", 22), password=bs.get("password"),
        timeout=30
    )
    return ssh


def clone_source(version: str, ssh: SSHClient = None):
    """拉取禅道源码"""
    logger.info(f"拉取禅道开源版 v{version} 源码...")
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    source_url = config.get("zentao", {}).get("source_url", "https://github.com/easysoft/zentaopms.git")
    mirror_url = config.get("zentao", {}).get("source_mirror", "https://gitee.com/easysoft/zentaopms.git")
    bs = config.get("build_server", {})
    build_dir = bs.get("build_dir", "/opt/build/zentaopms")

    if ssh:
        # 远程编译服务器拉取
        source_dir = f"{build_dir}/source"
        ssh.exec_ok(f"rm -rf {source_dir} && mkdir -p {source_dir}")
        for url in [source_url, mirror_url]:
            exit_code, out, err = ssh.exec_command(
                f"cd {build_dir} && "
                f"git clone --depth 1 --branch {version} {url} source 2>&1",
                timeout=120
            )
            if exit_code == 0:
                logger.info(f"  远程源码拉取成功: {build_dir}/source")
                return
            logger.warning(f"  拉取失败: {url}, 尝试镜像源...")
        raise RuntimeError(f"无法拉取禅道 v{version} 源码")
    else:
        # 本地拉取
        if os.path.exists(SOURCE_DIR):
            import shutil
            shutil.rmtree(SOURCE_DIR)
        os.makedirs(SOURCE_DIR, exist_ok=True)
        for url in [source_url, mirror_url]:
            try:
                subprocess.run(
                    ["git", "clone", "--depth", "1", "--branch", version, url, SOURCE_DIR],
                    check=True, capture_output=True, text=True, timeout=120
                )
                logger.info(f"  本地源码拉取成功: {SOURCE_DIR}")
                return
            except subprocess.CalledProcessError:
                logger.warning(f"  拉取失败，尝试镜像源...")
        raise RuntimeError(f"无法拉取禅道 v{version} 源码")


def build_image(version: str, registry: str, project: str, push: bool = False,
                local: bool = False):
    """构建 Docker 镜像（远程编译服务器或本地）"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    image_name = config.get("harbor", {}).get("image_name", "zentao")
    full_image = f"{registry}/{project}/{image_name}:{version}"
    latest_image = f"{registry}/{project}/{image_name}:latest"

    ssh = None if local else _get_build_ssh()

    # 1. 拉取源码
    if not os.path.exists(os.path.join(SOURCE_DIR, "www")) and local:
        clone_source(version)
    if ssh:
        clone_source(version, ssh)
        bs = config.get("build_server", {})
        build_dir = bs.get("build_dir", "/opt/build/zentaopms")

        # 2. 上传构建文件到编译服务器
        logger.info(f"上传构建文件到编译服务器 {bs['host']}...")
        for f in ["Dockerfile", ".dockerignore", "docker-entrypoint.sh"]:
            local_path = os.path.join(MODULE_DIR, f)
            remote_path = f"{build_dir}/{f}"
            ssh.upload_file(local_path, remote_path)
        logger.info("  构建文件上传完成")

        # 3. 远程 Docker 构建
        logger.info(f"远程 Docker build (约 5-15 分钟)...")
        exit_code, out, err = ssh.exec_command(
            f"cd {build_dir} && "
            f"docker build --build-arg ZENTAO_VERSION={version} "
            f"-t {full_image} -t {latest_image} -f Dockerfile . 2>&1",
            timeout=1200
        )
        if exit_code != 0:
            raise RuntimeError(f"远程 Docker 构建失败: {err[-500:]}")
        logger.info(f"  远程镜像构建完成: {full_image}")

        # 4. 远程推送
        if push:
            logger.info(f"  远程推送镜像到 {full_image}...")
            exit_code, _, err = ssh.exec_command(
                f"docker push {full_image} && docker push {latest_image} 2>&1",
                timeout=300
            )
            if exit_code != 0:
                raise RuntimeError(f"镜像推送失败: {err[:300]}")
            logger.info("  推送完成")
    else:
        # 本地构建
        if not os.path.exists(os.path.join(SOURCE_DIR, "www")):
            clone_source(version)

        logger.info("  本地 Docker build (多阶段编译，约 5-15 分钟)...")
        result = subprocess.run(
            ["docker", "build", "--build-arg", f"ZENTAO_VERSION={version}",
             "-t", full_image, "-t", latest_image,
             "-f", os.path.join(MODULE_DIR, "Dockerfile"), MODULE_DIR],
            capture_output=False, text=True
        )
        if result.returncode != 0:
            raise RuntimeError(f"Docker 构建失败: exit_code={result.returncode}")
        logger.info(f"  镜像构建完成: {full_image}")

        # 本地验证
        logger.info("  本地验证容器启动...")
        subprocess.run(["docker", "rm", "-f", "zentao-verify"], capture_output=True)
        subprocess.run(
            ["docker", "run", "-d", "--name", "zentao-verify", "-p", "18080:8080",
             "-e", "ZT_MYSQL_HOST=host.docker.internal", "-e", "ZT_MYSQL_PORT=3306",
             "-e", "ZT_MYSQL_USER=root", "-e", "ZT_MYSQL_PASSWORD=test",
             "-e", "ZT_MYSQL_DB=zentao", full_image],
            capture_output=True, text=True, timeout=30
        )
        subprocess.run(["docker", "rm", "-f", "zentao-verify"], capture_output=True)

        if push:
            logger.info(f"  推送镜像到 {full_image}...")
            subprocess.run(["docker", "push", full_image], check=True)
            subprocess.run(["docker", "push", latest_image], check=True)
            logger.info("  推送完成")

    return full_image


def main():
    parser = argparse.ArgumentParser(description="禅道镜像构建工具")
    parser.add_argument("--version", default="21.2", help="禅道版本号")
    parser.add_argument("--push", action="store_true", help="构建后推送到 Harbor")
    parser.add_argument("--skip-pull", action="store_true", help="跳过源码拉取")
    parser.add_argument("--local", action="store_true", help="强制本地构建（不使用远程编译服务器）")
    args = parser.parse_args()

    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    registry = config.get("harbor", {}).get("url", "").replace("https://", "").replace("http://", "")
    project = config.get("harbor", {}).get("project", "testops")

    if not args.skip_pull:
        clone_source(args.version, None if args.local else _get_build_ssh())

    image = build_image(args.version, registry, project, push=args.push, local=args.local)

    logger.info(f"\n{'='*50}")
    logger.info(f"  镜像构建完成: {image}")
    if not args.push:
        logger.info(f"  下一步: python build_image.py --push")
    logger.info(f"{'='*50}")


if __name__ == "__main__":
    main()
