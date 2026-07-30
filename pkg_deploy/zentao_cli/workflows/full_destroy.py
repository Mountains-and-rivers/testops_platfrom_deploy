"""
一键清理测试环境所有 K8s 业务资源
用法: python full_destroy.py [--delete-pvc] [--force]
"""

import sys
import os

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.log_utils import get_logger, setup_stdout_encoding
from common.yaml_render import YAMLHelper
from common.k8s_client import K8sClient

setup_stdout_encoding()
logger = get_logger(__name__)
CONFIG_DIR = os.path.join(PROJECT_ROOT, "configs")

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="一键清理")
    parser.add_argument("--delete-pvc", action="store_true", help="同时删除 PVC")
    parser.add_argument("--force", "-f", action="store_true", help="跳过确认")
    args = parser.parse_args()

    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    namespace = config.get("kubernetes", {}).get("namespace", "zentao")
    k8s = K8sClient(namespace=namespace)

    if not args.force:
        confirm = input(f"确认删除命名空间 {namespace} 全部资源? (yes/no): ")
        if confirm != "yes":
            logger.info("已取消")
            sys.exit(0)

    logger.info("一键清理开始...")
    for res in ["ingress", "service", "deployment", "configmap", "secret"]:
        k8s._kubectl(f"delete {res} --all -n {namespace} --ignore-not-found=true")
    if args.delete_pvc:
        k8s._kubectl(f"delete pvc --all -n {namespace} --ignore-not-found=true")
    k8s._kubectl(f"delete namespace {namespace} --ignore-not-found=true")
    logger.info("清理完成")
