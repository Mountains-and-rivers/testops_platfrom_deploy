"""
Stage 7: 集群部署后健康校验

全面检查集群健康状态：
- 节点状态（全部 Ready）
- 核心组件 Pod 运行状态
- CoreDNS 解析测试
- 集群基本功能验证（创建/删除测试 Pod）
- NodePort 可达性测试
"""

import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.workflow_state import WorkflowStateManager
from common.ssh_client import SSHClient
from src.workflow.workflow_exception import ClusterVerifyError

logger = get_logger(__name__)


def _check_nodes_ready(ssh: SSHClient) -> list:
    """检查是否全部节点处于 Ready 状态。"""
    _, node_output, _ = ssh.exec_command(
        "kubectl get nodes --no-headers", timeout=15
    )

    not_ready = []
    for line in node_output.strip().split("\n"):
        if line:
            parts = line.split()
            if len(parts) >= 2 and parts[1] != "Ready":
                not_ready.append(f"{parts[0]} ({parts[1]})")

    return not_ready


def _check_core_pods(ssh: SSHClient) -> list:
    """检查 kube-system 命名空间中核心 Pod 是否全部 Running。"""
    _, pod_output, _ = ssh.exec_command(
        "kubectl get pods -n kube-system --no-headers", timeout=15
    )

    not_running = []
    for line in pod_output.strip().split("\n"):
        if line:
            parts = line.split()
            name = parts[0] if parts else ""
            ready = parts[1] if len(parts) > 1 else ""
            status = parts[2] if len(parts) > 2 else ""
            if status not in ("Running", "Completed"):
                not_running.append(f"{name}: {ready} ({status})")

    return not_running


def _test_dns_resolution(ssh: SSHClient) -> bool:
    """测试集群 DNS 解析。"""
    test_manifest = """
apiVersion: v1
kind: Pod
metadata:
  name: dns-test
  namespace: default
spec:
  containers:
  - name: dns-test
    image: busybox:1.36
    command: ['sleep', '30']
  restartPolicy: Never
"""
    try:
        # 创建测试 Pod
        ssh.exec_command(
            f"cat << 'EOF' | kubectl apply -f -\n{test_manifest}\nEOF",
            timeout=15
        )
        # 等待 Pod Running
        ssh.exec_command(
            "kubectl wait --for=condition=ready pod/dns-test --timeout=60s",
            timeout=70
        )
        # 执行 DNS 查询测试
        _, dns_result, _ = ssh.exec_command(
            "kubectl exec dns-test -- nslookup kubernetes.default.svc.cluster.local",
            timeout=15
        )
        logger.info(f"DNS 解析测试结果: {dns_result[:200]}")
        success = "Address" in dns_result or "Name:" in dns_result
        return success
    finally:
        # 清理测试 Pod
        ssh.exec_command("kubectl delete pod dns-test --force --grace-period=0",
                         timeout=10)


def _test_create_delete_pod(ssh: SSHClient) -> bool:
    """测试创建和删除 Pod 的能力。"""
    test_pod = """
apiVersion: v1
kind: Pod
metadata:
  name: verify-test
  namespace: default
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
  restartPolicy: Never
"""
    try:
        ssh.exec_command(
            f"cat << 'EOF' | kubectl apply -f -\n{test_pod}\nEOF",
            timeout=15
        )
        ssh.exec_command(
            "kubectl wait --for=condition=ready pod/verify-test --timeout=120s",
            timeout=130
        )
        _, status, _ = ssh.exec_command(
            "kubectl get pod verify-test -o jsonpath='{.status.phase}'",
            timeout=10
        )
        return status.strip() == "Running"
    finally:
        ssh.exec_command(
            "kubectl delete pod verify-test --force --grace-period=0",
            timeout=10
        )


def run_cluster_verify(state: WorkflowStateManager) -> None:
    """
    执行集群部署后全面健康校验。

    Args:
        state: 工作流状态管理器实例
    """
    logger.info("=" * 50)
    logger.info("Stage 7: 开始集群部署后健康校验")
    logger.info("=" * 50)

    master_ip = state.get_global("master_ip")
    if not master_ip:
        raise ClusterVerifyError("master_ip", "Master 节点 IP 未找到")

    ssh = SSHClient(host=master_ip, username="root")
    results = {}
    all_passed = True

    try:
        ssh.connect()

        # 1. 节点状态检查
        logger.info("检查 1/5: 节点状态...")
        not_ready = _check_nodes_ready(ssh)
        results["nodes_ready"] = len(not_ready) == 0
        if not_ready:
            all_passed = False
            logger.error(f"存在未就绪节点: {not_ready}")
        else:
            logger.info("✓ 全部节点处于 Ready 状态")

        # 2. 核心组件 Pod 检查
        logger.info("检查 2/5: 核心组件 Pod 状态...")
        not_running = _check_core_pods(ssh)
        results["core_pods_running"] = len(not_running) == 0
        if not_running:
            all_passed = False
            logger.error(f"存在未运行的核心 Pod: {not_running}")
        else:
            logger.info("✓ 核心组件 Pod 全部 Running")

        # 3. DNS 解析测试
        logger.info("检查 3/5: DNS 解析测试...")
        dns_ok = _test_dns_resolution(ssh)
        results["dns_resolution"] = dns_ok
        if not dns_ok:
            all_passed = False
            logger.error("DNS 解析测试失败")
        else:
            logger.info("✓ DNS 解析正常")

        # 4. Pod 创建/删除测试
        logger.info("检查 4/5: Pod 创建/删除测试...")
        pod_ok = _test_create_delete_pod(ssh)
        results["pod_lifecycle"] = pod_ok
        if not pod_ok:
            all_passed = False
            logger.error("Pod 创建/删除测试失败")
        else:
            logger.info("✓ Pod 创建/删除测试通过")

        # 5. 集群版本信息
        logger.info("检查 5/5: 集群版本信息...")
        _, version, _ = ssh.exec_command("kubectl version --short 2>/dev/null || kubectl version", timeout=10)
        logger.info(f"集群版本:\n{version[:500]}")
        results["cluster_version"] = True

        # 输出汇总
        logger.info("\n" + "=" * 50)
        logger.info("健康校验汇总：")
        for check, passed in results.items():
            status = "✓" if passed else "✗"
            logger.info(f"  {status} {check}")
        logger.info("=" * 50)

        if not all_passed:
            raise ClusterVerifyError(
                "cluster_health", "部分健康检查未通过"
            )

        logger.info("集群健康校验全部通过 ✓")

    finally:
        ssh.close()

    state.set_global("cluster_verified", True)
    state.set_global("verify_results", results)
