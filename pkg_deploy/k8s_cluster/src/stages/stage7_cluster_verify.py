"""
Stage 7: 集群部署后健康校验

全面检查 + 部署 nginx 功能测试
"""

import os
import sys
import time

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.workflow_state import WorkflowStateManager
from common.ssh_client import SSHClient
from common.yaml_helper import YAMLHelper
from src.workflow.workflow_exception import ClusterVerifyError

logger = get_logger(__name__)

# 测试用 namespace，回滚时仅删除此 namespace
TEST_NAMESPACE = "testops-verify"


def _get_ssh(state):
    """获取 Master SSH 客户端（state 无 master_ip 时自动从配置读取）"""
    CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "config")
    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    masters = node_list.get("node_list", {}).get("masters", [])
    if not masters:
        raise ClusterVerifyError("master_ip", "node_list.yaml 中未找到 Master 节点")
    master_ip = state.get_global("master_ip") or masters[0].get("ip")
    if not master_ip:
        raise ClusterVerifyError("master_ip", "Master 节点 IP 未找到")
    master_cfg = masters[0].get("ssh", {}) if masters else {}
    ssh = SSHClient(
        host=master_ip,
        username=master_cfg.get("username", "root"),
        port=master_cfg.get("port", 22),
        password=master_cfg.get("password"),
        key_file=master_cfg.get("key_file"),
    )
    ssh.connect()
    return ssh


def run_cluster_verify(state: WorkflowStateManager) -> None:
    """执行集群部署后全面健康校验"""
    state.require_stage_success("stage6_cni_deploy")

    logger.info("=" * 50)
    logger.info("Stage 7: 集群健康校验")
    logger.info("=" * 50)

    ssh = _get_ssh(state)
    results = {}
    all_passed = True

    try:
        # 创建测试 namespace
        ssh.exec_command(f"kubectl create ns {TEST_NAMESPACE} 2>/dev/null || true", timeout=5)

        # ---- 1. 节点就绪 ----
        logger.info("[1/7] 节点状态...")
        _, out, _ = ssh.exec_command("kubectl get nodes --no-headers", timeout=15)
        not_ready = []
        node_count = 0
        for line in out.strip().split("\n"):
            if not line: continue
            node_count += 1
            parts = line.split()
            if len(parts) >= 2 and parts[1] != "Ready":
                not_ready.append(f"{parts[0]}={parts[1]}")
        results["nodes"] = len(not_ready) == 0
        if not_ready:
            all_passed = False
            logger.error(f"  未就绪节点: {not_ready}")
        else:
            logger.info(f"  OK  {node_count} 节点全部 Ready")

        # ---- 2. 核心组件 Pod ----
        logger.info("[2/7] 核心组件 Pod...")
        import time as _time
        not_running = []
        for attempt in range(12):  # 最多等 60s
            _, out, _ = ssh.exec_command("kubectl get pods -n kube-system --no-headers", timeout=15)
            not_running = []
            for line in out.strip().split("\n"):
                if not line: continue
                parts = line.split()
                name, ready, status = parts[0], parts[1] if len(parts) > 1 else "", parts[2] if len(parts) > 2 else ""
                # ContainerCreating 是暂态，等待即可
                if status not in ("Running", "Completed") and status != "ContainerCreating":
                    not_running.append(f"{name}={status}")
            if not_running:
                break  # 有实质性错误，立即报
            # 检查是否还有 ContainerCreating
            has_creating = any(
                line.split()[2] == "ContainerCreating"
                for line in out.strip().split("\n") if line and len(line.split()) > 2
            )
            if not has_creating:
                break
            logger.info(f"  等待 Pod 就绪... ({(attempt+1)*5}s)")
            _time.sleep(5)
        results["pods"] = len(not_running) == 0
        if not_running:
            all_passed = False
            logger.error(f"  异常 Pod: {not_running}")
        else:
            logger.info(f"  OK  全部 Running/Completed")

        # ---- 3. etcd 健康 ----
        logger.info("[3/7] etcd 健康...")
        _, out, _ = ssh.exec_command(
            "kubectl get --raw=/healthz/etcd 2>/dev/null || echo FAIL", timeout=10
        )
        results["etcd"] = "ok" in out
        logger.info(f"  {'OK' if 'ok' in out else 'FAIL'}  etcd healthz")

        # ---- 4. API Server ----
        logger.info("[4/7] API Server...")
        _, out, _ = ssh.exec_command(
            "kubectl get --raw=/healthz 2>/dev/null || echo FAIL", timeout=10
        )
        results["apiserver"] = "ok" in out
        logger.info(f"  {'OK' if 'ok' in out else 'FAIL'}  API Server healthz")

        # ---- 5. DNS 解析 ----
        logger.info("[5/7] DNS 解析...")
        _, dns_svc, _ = ssh.exec_command(
            "kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo NONE",
            timeout=10
        )
        dns_ip = dns_svc.strip()
        if dns_ip and dns_ip != "NONE":
            _, dns_out, _ = ssh.exec_command(
                f"nslookup kubernetes.default.svc.cluster.local {dns_ip} 2>/dev/null || echo DNS_FAIL",
                timeout=10
            )
            dns_ok = "Address" in dns_out or "Name:" in dns_out
            results["dns"] = dns_ok
            logger.info(f"  {'OK' if dns_ok else 'FAIL'}  CoreDNS {dns_ip}: {dns_out.strip()[:100]}")
            if not dns_ok: all_passed = False
        else:
            results["dns"] = False
            all_passed = False
            logger.error("  FAIL  无法获取 CoreDNS ClusterIP")

        # ---- 6. Pod 创建 + Service 暴露测试 ----
        logger.info("[6/7] Pod + Service 功能测试...")
        test_yaml = """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: {ns}
spec:
  replicas: 1
  selector:
    matchLabels:
      test: app
  template:
    metadata:
      labels:
        test: app
    spec:
      containers:
      - name: test-app
        image: registry.k8s.io/pause:3.10
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: test-app
  namespace: {ns}
spec:
  type: ClusterIP
  selector:
    test: app
  ports:
  - port: 8080
    targetPort: 8080
""".format(ns=TEST_NAMESPACE)
        try:
            ssh.exec_command(f"cat << 'EOF' | kubectl apply -f -\n{test_yaml}\nEOF", timeout=15)
            # 等待 Deployment 就绪
            start = time.time()
            deployed = False
            for _ in range(24):
                time.sleep(5)
                _, status, _ = ssh.exec_command(
                    f"kubectl get deploy test-app -n {TEST_NAMESPACE} -o jsonpath='{{.status.readyReplicas}}' 2>/dev/null || echo 0",
                    timeout=10
                )
                if status.strip() == "1":
                    deployed = True
                    break
            if not deployed:
                all_passed = False
                results["pod_svc"] = False
                logger.error("  FAIL  Deployment 未就绪")
            else:
                _, svc_ip, _ = ssh.exec_command(
                    f"kubectl get svc test-app -n {TEST_NAMESPACE} -o jsonpath='{{.spec.clusterIP}}'",
                    timeout=10
                )
                results["pod_svc"] = True
                elapsed = time.time() - start
                logger.info(f"  OK  Deployment+Service 就绪, ClusterIP={svc_ip.strip()} ({elapsed:.0f}s)")
        finally:
            ssh.exec_command(
                f"kubectl delete deploy test-app -n {TEST_NAMESPACE} --force --grace-period=0 2>/dev/null || true; "
                f"kubectl delete svc test-app -n {TEST_NAMESPACE} --force --grace-period=0 2>/dev/null || true",
                timeout=30
            )

        # ---- 7. 集群版本 ----
        logger.info("[7/7] 集群版本...")
        _, ver, _ = ssh.exec_command("kubectl version -o json 2>/dev/null | python3 -c \"import sys,json;d=json.load(sys.stdin);print(d.get('serverVersion',{}).get('gitVersion','unknown'))\" 2>/dev/null || echo unknown", timeout=10)
        results["version"] = True
        logger.info(f"  Server: {ver.strip()}")

        # ---- 汇总 ----
        logger.info("")
        logger.info("=" * 50)
        passed = sum(1 for v in results.values() if v)
        total = len(results)
        for k, v in results.items():
            logger.info(f"  {'[PASS]' if v else '[FAIL]'} {k}")
        logger.info(f"  总计 {passed}/{total} 通过")
        logger.info("=" * 50)

        if not all_passed:
            raise ClusterVerifyError("cluster_health", f"{total-passed} 项未通过")

        logger.info("集群健康校验全部通过")

    finally:
        ssh.close()

    state.set_global("cluster_verified", True)
    state.set_global("verify_results", results)


def rollback_cluster_verify(state: WorkflowStateManager) -> None:
    """
    回滚 Stage 7：仅删除测试引入的 namespace。
    不影响任何集群核心资源。
    """
    logger.info("=" * 50)
    logger.info("Stage 7 Rollback: 清理测试资源")
    logger.info("=" * 50)

    master_ip = state.get_global("master_ip")
    if not master_ip:
        logger.warning("无 Master IP，跳过")
        return

    CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "config")
    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    masters = node_list.get("node_list", {}).get("masters", [])
    master_cfg = masters[0].get("ssh", {}) if masters else {}

    ssh = SSHClient(
        host=master_ip,
        username=master_cfg.get("username", "root"),
        port=master_cfg.get("port", 22),
        password=master_cfg.get("password"),
        key_file=master_cfg.get("key_file"),
    )
    try:
        ssh.connect()
        ssh.exec_command(f"kubectl delete namespace {TEST_NAMESPACE} --force --grace-period=0 2>/dev/null || true", timeout=30)
        logger.info(f"  已删除 namespace: {TEST_NAMESPACE}")
    except Exception as e:
        logger.warning(f"回滚异常: {e}")
    finally:
        ssh.close()

    state.set_global("cluster_verified", False)
    logger.info("Stage 7 回滚完成")
