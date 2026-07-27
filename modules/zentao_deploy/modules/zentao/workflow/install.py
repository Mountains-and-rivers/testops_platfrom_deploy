"""
禅道一键部署至 K8s（读取外部 MySQL 配置）
用法: python install.py
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
K8S_BASE_DIR = os.path.join(CONFIG_DIR, "k8s_base")


def load_variables() -> dict:
    """加载配置变量"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    harbor = config.get("harbor", {})
    k8s = config.get("kubernetes", {})
    mysql = config.get("mysql", {})
    pvc = config.get("persistence", {})
    zentao = config.get("zentao", {})

    return {
        "NAMESPACE": k8s.get("namespace", "zentao"),
        "REGISTRY": harbor.get("url", "").replace("https://", "").replace("http://", ""),
        "HARBOR_PROJECT": harbor.get("project", "testops"),
        "IMAGE_NAME": harbor.get("image_name", "zentao"),
        "IMAGE_TAG": harbor.get("image_tag", "21.2"),
        "INGRESS_HOST": k8s.get("ingress_host", "zentao.testops.local"),
        "STORAGE_CLASS": k8s.get("storage_class", "nfs-client"),
        "MYSQL_HOST": mysql.get("host", "192.168.0.100"),
        "MYSQL_PORT": str(mysql.get("port", 3306)),
        "MYSQL_USER": mysql.get("user", "zentao"),
        "MYSQL_PASSWORD": mysql.get("password", ""),
        "MYSQL_DATABASE": mysql.get("database", "zentao"),
        "DATA_PVC_SIZE": pvc.get("data_pvc_size", "20Gi"),
        "CONFIG_PVC_SIZE": pvc.get("config_pvc_size", "1Gi"),
    }


def install_zentao():
    """一键部署禅道到 K8s"""
    vars_dict = load_variables()
    namespace = vars_dict["NAMESPACE"]
    k8s = K8sClient(namespace=namespace)

    logger.info("=" * 50)
    logger.info("  禅道开源版 K8s 部署开始")
    logger.info("=" * 50)

    # 1. 创建 Namespace
    logger.info("[1/6] 创建 Namespace...")
    YAMLHelper.render_template(os.path.join(K8S_BASE_DIR, "namespace.yaml"), vars_dict,
                               os.path.join(CONFIG_DIR, "rendered", "namespace.yaml"))
    k8s.apply(os.path.join(CONFIG_DIR, "rendered", "namespace.yaml"))

    # 2. 创建 Secret
    logger.info("[2/6] 创建 K8s Secret...")
    YAMLHelper.render_template(os.path.join(K8S_BASE_DIR, "secret_template.yaml"), vars_dict,
                               os.path.join(CONFIG_DIR, "rendered", "secret.yaml"))
    k8s.apply(os.path.join(CONFIG_DIR, "rendered", "secret.yaml"))

    # 3. 创建 PVC
    logger.info("[3/6] 创建持久化存储 PVC...")
    YAMLHelper.render_template(os.path.join(K8S_BASE_DIR, "pvc_template.yaml"), vars_dict,
                               os.path.join(CONFIG_DIR, "rendered", "pvc.yaml"))
    k8s.apply(os.path.join(CONFIG_DIR, "rendered", "pvc.yaml"))

    # 部署清单（按顺序）
    manifests = [
        ("zentao_configmap.yaml", "ConfigMap"),
        ("zentao_deploy.yaml", "Deployment"),
        ("zentao_service.yaml", "Service"),
        ("zentao_ingress.yaml", "Ingress"),
    ]

    for idx, (filename, desc) in enumerate(manifests, 4):
        logger.info(f"[{idx}/6] 部署 {desc}...")
        rendered_path = os.path.join(CONFIG_DIR, "rendered", filename)
        YAMLHelper.render_template(os.path.join(MANIFEST_DIR, filename), vars_dict, rendered_path)
        k8s.apply(rendered_path)

    # 5. 等待 Pod 就绪
    logger.info("[6/6] 等待禅道 Pod 就绪...")
    if k8s.pod_ready("app=zentao", namespace):
        logger.info(f"  禅道已就绪! 访问: http://{vars_dict['INGRESS_HOST']}")
    else:
        logger.error("  Pod 未能在超时时间内就绪，请检查日志")

    logger.info("=" * 50)
    logger.info("  部署完成")
    logger.info("=" * 50)


if __name__ == "__main__":
    install_zentao()
