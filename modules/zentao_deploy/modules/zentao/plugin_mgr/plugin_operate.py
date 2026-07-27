"""
禅道插件管理 — 在线/离线安装、挂载校验
用法: python plugin_operate.py install <plugin_name>
     python plugin_operate.py install-offline <plugin_zip_path>
     python plugin_operate.py list
"""

import os
import sys
import subprocess

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.log_utils import get_logger, setup_stdout_encoding
from common.yaml_render import YAMLHelper
from common.k8s_client import K8sClient

setup_stdout_encoding()
logger = get_logger(__name__)
CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "configs")
PLUGIN_DIR = os.path.dirname(__file__)


def get_zentao_pod(k8s: K8sClient, namespace: str) -> str:
    """获取禅道 Pod 名称"""
    r = k8s._kubectl(
        f"get pods -n {namespace} -l app=zentao -o jsonpath='{{.items[0].metadata.name}}'",
        timeout=10
    )
    name = r.stdout.strip()
    if not name:
        raise RuntimeError("未找到禅道 Pod")
    return name


def install_plugin_online(plugin_name: str):
    """在线安装插件"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    namespace = config.get("kubernetes", {}).get("namespace", "zentao")
    k8s = K8sClient(namespace=namespace)
    pod = get_zentao_pod(k8s, namespace)

    logger.info(f"在线安装插件: {plugin_name}")
    r = k8s._kubectl(
        f"exec -n {namespace} {pod} -- "
        f"php /var/www/zentaopms/bin/ztcli.php plugin-install {plugin_name}",
        timeout=120
    )
    logger.info(r.stdout.strip() or r.stderr.strip()[:500])
    logger.info("安装完成（需在禅道后台激活插件）")


def install_plugin_offline(zip_path: str):
    """离线安装插件（插件包上传到 PVC）"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    namespace = config.get("kubernetes", {}).get("namespace", "zentao")
    k8s = K8sClient(namespace=namespace)
    pod = get_zentao_pod(k8s, namespace)

    if not os.path.exists(zip_path):
        logger.error(f"插件包不存在: {zip_path}")
        return

    # 上传到 Pod
    remote_path = f"/var/www/zentaopms/tmp/{os.path.basename(zip_path)}"
    logger.info(f"上传插件包: {zip_path} → {pod}:{remote_path}")
    r = subprocess.run(
        f"kubectl cp {zip_path} {namespace}/{pod}:{remote_path}",
        shell=True, capture_output=True, text=True, timeout=30
    )
    if r.returncode != 0:
        logger.error(f"上传失败: {r.stderr[:300]}")
        return

    # 安装
    logger.info("安装插件...")
    r = k8s._kubectl(
        f"exec -n {namespace} {pod} -- "
        f"php /var/www/zentaopms/bin/ztcli.php plugin-install {remote_path}",
        timeout=120
    )
    logger.info(r.stdout.strip() or r.stderr.strip()[:500])
    logger.info("安装完成")


def list_plugins():
    """列出已安装插件"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    namespace = config.get("kubernetes", {}).get("namespace", "zentao")
    k8s = K8sClient(namespace=namespace)
    pod = get_zentao_pod(k8s, namespace)
    r = k8s._kubectl(
        f"exec -n {namespace} {pod} -- ls /var/www/zentaopms/module/",
        timeout=10
    )
    logger.info(f"已安装模块:\n{r.stdout.strip()}")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="禅道插件管理")
    sub = parser.add_subparsers(dest="cmd")

    p_online = sub.add_parser("install", help="在线安装插件")
    p_online.add_argument("plugin_name", help="插件名称")

    p_offline = sub.add_parser("install-offline", help="离线安装插件")
    p_offline.add_argument("zip_path", help="插件 zip 包路径")

    sub.add_parser("list", help="列出已安装插件")

    args = parser.parse_args()
    if args.cmd == "install":
        install_plugin_online(args.plugin_name)
    elif args.cmd == "install-offline":
        install_plugin_offline(args.zip_path)
    elif args.cmd == "list":
        list_plugins()
    else:
        parser.print_help()
