"""
Stage 6: Calico 网络插件部署

在集群中部署 Calico CNI 网络插件
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
from common.yaml_helper import YAMLHelper
from common.ssh_client import SSHClient
from src.workflow.workflow_exception import CNIDeployError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "config")

def run_cni_deploy(state: WorkflowStateManager) -> None:
    """部署 Calico CNI"""
    logger.info("=" * 50)
    logger.info("Stage 6: 开始 CNI 网络插件部署 (Calico)")
    logger.info("=" * 50)

    state.require_stage_success("stage5_node_join")

    cluster_info = YAMLHelper.load(os.path.join(CONFIG_DIR, "cluster_info.yaml"))
    calico_cfg = cluster_info.get("cluster_info", {}).get("cni", {}).get("calico", {})

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    masters = node_list.get("node_list", {}).get("masters", [])
    if not masters:
        raise CNIDeployError("calico", "node_list.yaml 中未找到 Master 节点")

    master_ip = state.get_global("master_ip") or masters[0].get("ip")
    if not master_ip:
        raise CNIDeployError("calico", "未找到 Master 节点 IP")
    master_cfg = masters[0].get("ssh", {})

    ssh = SSHClient(
        host=master_ip,
        username=master_cfg.get("username", "root"),
        port=master_cfg.get("port", 22),
        password=master_cfg.get("password"),
        key_file=master_cfg.get("key_file"),
    )

    try:
        ssh.connect()

        # 从配置读取 Calico 版本
        calico_ver = calico_cfg.get("version", "v3.29.1")

        # Calico manifest URL（国内优先 ghproxy）
        CALICO_URLS = [
            f"https://ghproxy.net/https://raw.githubusercontent.com/projectcalico/calico/{calico_ver}/manifests/calico.yaml",
            f"https://mirror.ghproxy.com/https://raw.githubusercontent.com/projectcalico/calico/{calico_ver}/manifests/calico.yaml",
            f"https://raw.githubusercontent.com/projectcalico/calico/{calico_ver}/manifests/calico.yaml",
        ]

        # 1. 下载 manifest
        logger.info("下载 Calico manifest...")
        downloaded = False
        for idx, url in enumerate(CALICO_URLS):
            logger.info(f"  尝试 [{idx+1}/{len(CALICO_URLS)}]: {url.split('/')[2]}")
            exit_code, _, _ = ssh.exec_command(
                f"curl -sL --connect-timeout 10 -o /tmp/calico.yaml '{url}' 2>&1 || echo FAILED",
                timeout=30
            )
            if exit_code == 0 and "FAILED" not in _:
                _, size, _ = ssh.exec_command("wc -c < /tmp/calico.yaml", timeout=5)
                if size.strip().isdigit() and int(size.strip()) > 1000:
                    downloaded = True
                    logger.info(f"  OK ({size.strip()} bytes)")
                    break
        if not downloaded:
            raise CNIDeployError("calico", "manifest 下载失败")

        # 2. 修改 Pod 网段
        net = cluster_info.get("cluster_info", {}).get("networking", {})
        pod_cidr = net.get("pod_cidr", "10.244.0.0/16")
        if pod_cidr != "192.168.0.0/16":
            ssh.exec_command_ok(f"sed -i 's|192.168.0.0/16|{pod_cidr}|g' /tmp/calico.yaml")
            logger.info(f"Pod 网段 → {pod_cidr}")

        # 3. 替换镜像源为 quay.io（containerd mirror 自动重定向到阿里云 quayio 加速）
        ssh.exec_command("sed -i 's|docker.io/calico/|quay.io/calico/|g' /tmp/calico.yaml", timeout=5)
        logger.info("镜像源 → quay.io (containerd mirror → registry.cn-hangzhou.aliyuncs.com/quayio)")

        # 4. 部署
        logger.info("部署 Calico...")
        exit_code, stdout, stderr = ssh.exec_command("kubectl apply -f /tmp/calico.yaml", timeout=120)
        if exit_code != 0:
            raise CNIDeployError("calico", f"apply 失败: {stderr[:300]}")
        logger.info("manifest 已应用")

        # 5. 等待就绪
        logger.info("等待 Calico Pods（最多 300 秒）...")
        wait_cmd = (
            "kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s && "
            "kubectl wait --for=condition=ready pod -l k8s-app=calico-kube-controllers -n kube-system --timeout=300s"
        )
        exit_code, _, w_err = ssh.exec_command(wait_cmd, timeout=320)
        if exit_code != 0:
            _, pod_status, _ = ssh.exec_command("kubectl get pods -n kube-system | grep calico", timeout=10)
            logger.warning(f"Calico Pod 状态:\n{pod_status}")
            raise CNIDeployError("calico", f"Pods 未就绪: {w_err[:200]}")

        # 6. 验证
        logger.info("安装后扫描...")
        _, nodes, _ = ssh.exec_command("kubectl get nodes --no-headers 2>/dev/null", timeout=10)
        ready_cnt = nodes.count("Ready")
        logger.info(f"  节点: {ready_cnt} Ready")
        _, coredns, _ = ssh.exec_command(
            "kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running || echo 0",
            timeout=10
        )
        logger.info(f"  CoreDNS: {coredns.strip()} Running")

        logger.info("Calico 部署完成")

    except CNIDeployError:
        raise
    except Exception as e:
        raise CNIDeployError("calico", str(e))
    finally:
        ssh.close()

    state.set_global("cni_deployed", True)
    state.set_global("cni_plugin", "calico")


def rollback_cni_deploy(state: WorkflowStateManager) -> None:
    """回滚 Calico"""
    logger.info("=" * 50)
    logger.info("Stage 6 Rollback: 回滚 CNI")
    logger.info("=" * 50)

    master_ip = state.get_global("master_ip")
    if not master_ip:
        node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
        masters = node_list.get("node_list", {}).get("masters", [])
        master_ip = masters[0].get("ip") if masters else None
    if not master_ip:
        logger.warning("无 Master IP，跳过")
        return

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
        # 按 label 全删
        ssh.exec_command(
            "kubectl delete ds -n kube-system calico-node --force --grace-period=0 2>/dev/null || true; "
            "kubectl delete deploy -n kube-system calico-kube-controllers --force --grace-period=0 2>/dev/null || true; "
            "kubectl delete pods -n kube-system -l k8s-app=calico-node --force --grace-period=0 2>/dev/null || true; "
            "kubectl delete pods -n kube-system -l k8s-app=calico-kube-controllers --force --grace-period=0 2>/dev/null || true; "
            "kubectl delete namespace calico-system --force --grace-period=0 2>/dev/null || true; "
            "kubectl delete namespace tigera-operator --force --grace-period=0 2>/dev/null || true; "
            "rm -f /tmp/calico.yaml",
            timeout=120
        )
        logger.info("Calico 卸载完成")
    except Exception as e:
        logger.warning(f"回滚异常: {e}")
    finally:
        ssh.close()

    # 所有节点清 CNI 接口
    for node in masters + node_list.get("node_list", {}).get("workers", []):
        sc = node.get("ssh", {})
        ns = SSHClient(host=node["ip"], username=sc.get("username","root"),
                      port=sc.get("port",22), password=sc.get("password"))
        try:
            ns.connect()
            ns.exec_command(
                "ip link delete cni0 2>/dev/null || true; "
                "ip link delete cali* 2>/dev/null || true; "
                "ip link delete vxlan.calico 2>/dev/null || true; "
                "rm -rf /etc/cni/net.d/* 2>/dev/null || true",
                timeout=10
            )
        except Exception:
            pass
        finally:
            ns.close()

    logger.info("CNI 回滚完成")
    state.set_global("cni_deployed", False)
