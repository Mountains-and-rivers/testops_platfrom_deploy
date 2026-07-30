"""
Java 业务应用部署脚本（供 Jenkins 流水线调用）
用法: python deploy_app.py --image harbor.testops.local/testops/java-app:v1.0 --env test
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
MANIFEST_DIR = os.path.dirname(os.path.dirname(__file__))


def deploy_app(image_full: str, env: str = "test"):
    """部署 Java 应用到 K8s 指定环境"""
    config = YAMLHelper.load(os.path.join(PROJECT_ROOT, "configs", "global.yaml"))
    namespace = env if env in ("test", "staging") else "test"
    k8s = K8sClient(namespace=namespace)

    # 解析镜像地址
    registry = config.get("harbor", {}).get("url", "").replace("https://", "").replace("http://", "")
    image_tag = image_full.split(":")[-1] if ":" in image_full else "latest"

    vars_dict = {
        "NAMESPACE": namespace,
        "REGISTRY": registry,
        "IMAGE_TAG": image_tag,
    }

    from common.yaml_render import YAMLHelper
    rendered = os.path.join(PROJECT_ROOT, "configs", "rendered", "app_deploy.yaml")
    YAMLHelper.render_template(os.path.join(MANIFEST_DIR, "manifests", "app_deploy.yaml"),
                               vars_dict, rendered)
    k8s.apply(rendered)
    k8s.rollout_status("deployment", "java-app", namespace, timeout=60)
    logger.info(f"Java App 部署完成: {image_full}")


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--image", required=True)
    p.add_argument("--env", default="test")
    args = p.parse_args()
    deploy_app(args.image, args.env)
