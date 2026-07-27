"""
禅道版本升级 — 滚动更新 Deployment 镜像
用法: python upgrade.py --version 21.2
"""

import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.log_utils import get_logger, setup_stdout_encoding
from common.yaml_render import YAMLHelper
from common.k8s_client import K8sClient

setup_stdout_encoding()
logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "configs")
MANIFEST_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "manifests")


def upgrade_zentao(version: str):
    """升级禅道到指定版本"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    namespace = config.get("kubernetes", {}).get("namespace", "zentao")
    k8s = K8sClient(namespace=namespace)

    logger.info("=" * 50)
    logger.info(f"  禅道升级 → v{version}")
    logger.info("=" * 50)

    # 重新渲染 Deployment 模板，更新镜像 tag
    vars_dict = {
        "NAMESPACE": namespace,
        "REGISTRY": config.get("harbor", {}).get("url", "").replace("https://", "").replace("http://", ""),
        "HARBOR_PROJECT": config.get("harbor", {}).get("project", "testops"),
        "IMAGE_NAME": config.get("harbor", {}).get("image_name", "zentao"),
        "IMAGE_TAG": version,
        "MYSQL_HOST": config.get("mysql", {}).get("host", "192.168.0.100"),
        "MYSQL_PORT": str(config.get("mysql", {}).get("port", 3306)),
        "STORAGE_CLASS": config.get("kubernetes", {}).get("storage_class", "nfs-client"),
    }
    rendered_path = os.path.join(CONFIG_DIR, "rendered", "zentao_deploy.yaml")
    YAMLHelper.render_template(os.path.join(MANIFEST_DIR, "zentao_deploy.yaml"), vars_dict, rendered_path)

    k8s.apply(rendered_path)

    if k8s.rollout_status("deployment", "zentao", namespace, timeout=120):
        logger.info(f"  升级完成: v{version}")
    else:
        logger.error("  升级失败，请检查 Pod 状态")

    logger.info("=" * 50)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="禅道版本升级")
    parser.add_argument("--version", "-v", required=True, help="目标版本号")
    args = parser.parse_args()
    upgrade_zentao(args.version)
