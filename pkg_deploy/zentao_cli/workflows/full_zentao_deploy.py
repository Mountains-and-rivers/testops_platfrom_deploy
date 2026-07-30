"""
跨模块串联工作流：源码构建镜像 → 推送 Harbor → 部署禅道 → 健康检查
用法: python full_zentao_cli.py [--version 21.2] [--skip-build]
"""

import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.log_utils import get_logger, setup_stdout_encoding
from common.yaml_render import YAMLHelper
from common.harbor_client import HarborClient
from common.pre_check import run_pre_check

setup_stdout_encoding()
logger = get_logger(__name__)
CONFIG_DIR = os.path.join(PROJECT_ROOT, "configs")


def full_deploy(version: str = "21.2", skip_build: bool = False):
    """完整禅道部署工作流"""
    logger.info("=" * 60)
    logger.info("  ZenTao 完整部署流水线启动")
    logger.info(f"  版本: v{version}")
    logger.info("=" * 60)

    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))

    # Step 0: 环境预检
    logger.info("[Step 1/5] 环境预检...")
    if not run_pre_check(config):
        logger.error("预检未通过，终止部署")
        sys.exit(1)

    # Step 1: 构建镜像
    if not skip_build:
        logger.info("[Step 2/5] 源码构建 Docker 镜像...")
        from pkg_deploy.zentao.build.build_image import clone_source, build_image
        harbor_cfg = config.get("harbor", {})
        registry = harbor_cfg.get("url", "").replace("https://", "").replace("http://", "")
        project = harbor_cfg.get("project", "testops")
        clone_source(version)
        build_image(version, registry, project, push=True)
    else:
        logger.info("[Step 2/5] 跳过构建（使用已有镜像）")

    # Step 2: 部署到 K8s
    logger.info("[Step 3/5] 部署禅道到 K8s...")
    from pkg_deploy.zentao.workflow.install import install_zentao
    install_zentao()

    # Step 3: 健康检查
    logger.info("[Step 4/5] 部署后健康检查...")
    from pkg_deploy.zentao.verify.health_check import check_zentao_health
    if not check_zentao_health():
        logger.error("健康检查未通过")
        sys.exit(1)

    # Step 4: 输出访问信息
    ingress_host = config.get("kubernetes", {}).get("ingress_host", "zentao.testops.local")
    logger.info("[Step 5/5] 部署完成!")
    logger.info(f"  禅道访问地址: http://{ingress_host}")
    logger.info(f"  初始化向导: http://{ingress_host}/install.php")
    logger.info("=" * 60)

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="禅道完整部署")
    parser.add_argument("--version", default="21.2", help="禅道版本")
    parser.add_argument("--skip-build", action="store_true", help="跳过镜像构建")
    args = parser.parse_args()
    full_deploy(args.version, args.skip_build)
