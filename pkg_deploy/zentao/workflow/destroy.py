"""
禅道一键销毁 — 删除 K8s 中禅道全部资源（保留 PVC 数据）
用法: python destroy.py [--delete-pvc] [--force]
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


def destroy_zentao(delete_pvc: bool = False, force: bool = False):
    """销毁禅道 K8s 资源"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    namespace = config.get("kubernetes", {}).get("namespace", "zentao")
    k8s = K8sClient(namespace=namespace)

    if not force:
        confirm = input(f"确认删除命名空间 {namespace} 内所有禅道资源? (yes/no): ")
        if confirm != "yes":
            logger.info("已取消")
            return

    logger.info("=" * 50)
    logger.info("  禅道 K8s 资源销毁")
    logger.info("=" * 50)

    # 逆序删除
    resources = [
        ("Ingress", "zentao-ingress"),
        ("Service", "zentao-svc"),
        ("Deployment", "zentao"),
        ("ConfigMap", "zentao-config"),
        ("Secret", "zentao-secret"),
    ]

    for res_type, name in resources:
        logger.info(f"  删除 {res_type}/{name}...")
        if k8s.resource_exists(res_type.lower(), name, namespace):
            k8s._kubectl(f"delete {res_type.lower()} {name} -n {namespace} --ignore-not-found=true")

    if delete_pvc:
        logger.info("  删除 PVC（数据将永久丢失）...")
        for pvc in ["zentao-data-pvc", "zentao-config-pvc"]:
            k8s._kubectl(f"delete pvc {pvc} -n {namespace} --ignore-not-found=true")

    logger.info("=" * 50)
    logger.info("  销毁完成")
    logger.info("=" * 50)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="禅道资源销毁")
    parser.add_argument("--delete-pvc", action="store_true", help="同时删除 PVC（数据永久丢失）")
    parser.add_argument("--force", "-f", action="store_true", help="跳过确认")
    args = parser.parse_args()
    destroy_zentao(delete_pvc=args.delete_pvc, force=args.force)
