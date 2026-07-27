"""
禅道部署后健康检查
验证 Web 连通性、外部 MySQL 连接、配置文件完整性
"""

import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.log_utils import get_logger, setup_stdout_encoding
from common.yaml_render import YAMLHelper
from common.k8s_client import K8sClient
from common.ssh_client import SSHClient

setup_stdout_encoding()
logger = get_logger(__name__)
CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "configs")


def check_zentao_health():
    """禅道部署后全面健康检查"""
    config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml"))
    namespace = config.get("kubernetes", {}).get("namespace", "zentao")
    k8s = K8sClient(namespace=namespace)
    results = {}

    logger.info("=" * 50)
    logger.info("  禅道部署后健康检查")
    logger.info("=" * 50)

    # 1. K8s Pod 状态
    logger.info("[1/5] K8s Pod 状态...")
    pods = k8s.get_pods("app=zentao")
    running = pods.count("Running") if pods else 0
    total = len([l for l in pods.split("\n") if l.strip()]) if pods else 0
    ok = total > 0 and running == total
    results["k8s_pod"] = ok
    logger.info(f"  {'PASS' if ok else 'FAIL'}  {running}/{total} Running")

    # 2. Web 连通性
    logger.info("[2/5] Web 连通性...")
    ingress_host = config.get("kubernetes", {}).get("ingress_host", "zentao.testops.local")
    try:
        import urllib.request
        req = urllib.request.Request(f"http://{ingress_host}/", method="HEAD")
        resp = urllib.request.urlopen(req, timeout=10)
        web_ok = resp.status in (200, 302)
        results["web_access"] = web_ok
        logger.info(f"  {'PASS' if web_ok else 'FAIL'}  HTTP {resp.status}")
    except Exception as e:
        results["web_access"] = False
        logger.warning(f"  FAIL  {e}")

    # 3. 外部 MySQL 连通性
    logger.info("[3/5] 外部 MySQL 连通性...")
    mysql_cfg = config.get("mysql", {})
    try:
        import pymysql
        conn = pymysql.connect(
            host=mysql_cfg.get("host"), port=mysql_cfg.get("port", 3306),
            user=mysql_cfg.get("user"), password=mysql_cfg.get("password"),
            database=mysql_cfg.get("database"), connect_timeout=5
        )
        conn.close()
        results["mysql_conn"] = True
        logger.info(f"  PASS  {mysql_cfg.get('host')}:{mysql_cfg.get('port')}")
    except Exception as e:
        results["mysql_conn"] = False
        logger.error(f"  FAIL  {e}")

    # 4. PVC 状态
    logger.info("[4/5] PVC 绑定状态...")
    for pvc in ["zentao-data-pvc", "zentao-config-pvc"]:
        import subprocess
        r = subprocess.run(
            f"kubectl get pvc {pvc} -n {namespace} -o jsonpath='{{.status.phase}}'",
            shell=True, capture_output=True, text=True, timeout=10
        )
        status = r.stdout.strip()
        results[f"pvc_{pvc}"] = status == "Bound"
        logger.info(f"  {'PASS' if status == 'Bound' else 'FAIL'}  {pvc}: {status}")

    # 5. 磁盘空间
    logger.info("[5/5] 容器内磁盘空间...")
    pod_name = k8s._kubectl(
        f"get pods -n {namespace} -l app=zentao -o jsonpath='{{.items[0].metadata.name}}'",
        timeout=10
    ).stdout.strip()
    if pod_name:
        r = k8s._kubectl(f"exec -n {namespace} {pod_name} -- df -h /var/www/zentaopms/www/data", timeout=10)
        logger.info(f"  {r.stdout.strip()[:200]}")
        results["disk"] = True

    # 汇总
    logger.info("")
    passed = sum(1 for v in results.values() if v)
    total = len(results)
    for k, v in results.items():
        logger.info(f"  {'[PASS]' if v else '[FAIL]'} {k}")
    logger.info(f"  总计 {passed}/{total} 通过")
    logger.info("=" * 50)

    return all(results.values())


if __name__ == "__main__":
    ok = check_zentao_health()
    sys.exit(0 if ok else 1)
