"""
Stage 5: Node 节点加入集群

在所有 Worker 节点上执行 kubeadm join：
- 从状态中获取 join command
- 如 token 已过期，从 Master 重新生成
- 并行将 Worker 节点加入集群
- 为节点打上预设的标签（labels）
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
from src.workflow.workflow_exception import NodeJoinError, TokenExpiredError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")


def _join_single_worker(worker: dict, state: WorkflowStateManager) -> None:
    """将单个 Worker 节点加入集群。"""
    hostname = worker["hostname"]
    ip = worker["ip"]
    ssh_cfg = worker.get("ssh", {})

    join_cmd = state.get_global("join_command")
    if not join_cmd:
        raise NodeJoinError(hostname, "未找到 join 命令，请确认 Master 已初始化")

    ssh = SSHClient(
        host=ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
        password=ssh_cfg.get("password"),
        key_file=ssh_cfg.get("key_file"),
    )
    try:
        ssh.connect()
        logger.info(f"[{hostname}] 开始加入集群...")

        # 预拉 Worker 必需镜像（pause + kube-proxy + coredns 从阿里云）
        logger.info(f"[{hostname}] 预拉 Worker 镜像...")
        # 获取 containerd sandbox 版本
        _, pause_ver, _ = ssh.exec_command(
            "grep sandbox_image /etc/containerd/config.toml 2>/dev/null | "
            "grep -oP 'pause:\\K[^\"]+' || echo '3.10.2'",
            timeout=5
        )
        pv = pause_ver.strip() or "3.10.2"
        kv = state.get_global("k8s_version", "1.36.3")
        # Worker 需要的所有 kube-system 镜像
        pre_pull_images = [
            f"registry.k8s.io/pause:{pv}",              # sandbox
            f"registry.k8s.io/kube-proxy:v{kv}",        # kube-proxy daemonset
            f"registry.k8s.io/coredns/coredns:v1.14.2",  # coredns deployment
        ]
        MIRROR = "registry.cn-hangzhou.aliyuncs.com/google_containers"
        for img in pre_pull_images:
            # 检查是否已存在
            _, check, _ = ssh.exec_command(
                f"ctr -n k8s.io image ls -q | grep -cF '{img}' || echo 0", timeout=5
            )
            if check.strip() != "0":
                logger.info(f"[{hostname}]   ✓ {img.split('/')[-1]} 已存在")
                continue

            # 构造镜像源候选
            flat_name = img.split("/")[-1].split(":")[0]
            tag = img.split(":")[-1]
            candidates = [f"{MIRROR}/{flat_name}:{tag}"]
            # 带路径的（coredns/coredns → 扁平化）
            if "/" in img.replace("registry.k8s.io/", "").split(":")[0]:
                candidates.insert(0, img.replace("registry.k8s.io", MIRROR))

            for candidate in candidates:
                exit_code, _, _ = ssh.exec_command(
                    f"ctr -n k8s.io image pull {candidate} 2>&1 | tail -1", timeout=60
                )
                if exit_code == 0:
                    if candidate != img:
                        ssh.exec_command(
                            f"ctr -n k8s.io image tag {candidate} {img} && "
                            f"ctr -n k8s.io image remove {candidate}", timeout=10
                        )
                    logger.info(f"[{hostname}]   ✓ {img.split('/')[-1]}")
                    break

        # 执行 join（不用 sudo，SSH 已是 root）
        exit_code, stdout, stderr = ssh.exec_command(
            f"{join_cmd} --ignore-preflight-errors=all",
            sudo=False, timeout=120
        )

        if exit_code != 0:
            if "token" in stderr.lower() and "expired" in stderr.lower():
                raise TokenExpiredError()
            raise NodeJoinError(hostname, f"加入集群失败: {stderr[:300]}")

        logger.info(f"[{hostname}] 节点加入成功 ✓")

        # 打标签
        labels = worker.get("labels", {})
        if labels:
            master_ip = state.get_global("master_ip")
            master_ssh = SSHClient(
                host=master_ip,
                username=ssh_cfg.get("username", "root"),
                port=ssh_cfg.get("port", 22),
                password=ssh_cfg.get("password"),
                key_file=ssh_cfg.get("key_file"),
            )
            try:
                master_ssh.connect()
                for k, v in labels.items():
                    label_cmd = f"kubectl label node {hostname} {k}={v} --overwrite"
                    master_ssh.exec_command(label_cmd, timeout=10)
                logger.info(f"[{hostname}] 标签已设置: {labels}")
            finally:
                master_ssh.close()

    except (NodeJoinError, TokenExpiredError):
        raise
    except Exception as e:
        raise NodeJoinError(hostname, str(e))
    finally:
        ssh.close()


def run_node_join(state: WorkflowStateManager) -> None:
    """
    将全部 Worker 节点加入集群。

    Args:
        state: 工作流状态管理器实例
    """
    logger.info("=" * 50)
    logger.info("Stage 5: 开始 Node 节点加入集群")
    logger.info("=" * 50)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    workers = node_list.get("node_list", {}).get("workers", [])

    if not workers:
        logger.warning("未找到 Worker 节点定义，跳过此阶段")
        state.skip_stage("stage5_node_join", "无 Worker 节点")
        return

    for worker in workers:
        _join_single_worker(worker, state)

    logger.info(f"全部 {len(workers)} 个 Worker 节点已加入集群")
    state.set_global("node_join_completed", True)
    state.set_global("joined_workers", len(workers))


def rollback_node_join(state: WorkflowStateManager) -> None:
    """
    回滚 Stage 5：从集群中移除 Worker 节点并执行 kubeadm reset。

    操作：
    - kubectl drain（驱逐 Pod）
    - kubectl delete node（从集群移除）
    - SSH 到 Worker 执行 kubeadm reset
    """
    logger.info("=" * 50)
    logger.info("Stage 5 Rollback: 回滚 Node 加入")
    logger.info("=" * 50)

    master_ip = state.get_global("master_ip")
    if not master_ip:
        logger.warning("未找到 Master 节点 IP")
        return

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    workers = node_list.get("node_list", {}).get("workers", [])

    if not workers:
        logger.info("无 Worker 节点需要回滚")
        return

    # 先通过 Master 驱逐和删除节点
    masters = node_list.get("node_list", {}).get("masters", [])
    master_cfg = masters[0].get("ssh", {}) if masters else {}
    master_ssh = SSHClient(
        host=master_ip,
        username=master_cfg.get("username", "root"),
        port=master_cfg.get("port", 22),
        password=master_cfg.get("password"),
        key_file=master_cfg.get("key_file"),
    )

    for worker in workers:
        hostname = worker["hostname"]
        ip = worker["ip"]
        ssh_cfg = worker.get("ssh", {})

        try:
            master_ssh.connect()

            # drain + delete
            master_ssh.exec_command(
                f"kubectl drain {hostname} --force --ignore-daemonsets --delete-emptydir-data --timeout=60s 2>/dev/null || true",
                timeout=90
            )
            master_ssh.exec_command(
                f"kubectl delete node {hostname} 2>/dev/null || true", timeout=30
            )
            logger.info(f"[{hostname}] 已从集群移除")

        except Exception as e:
            logger.warning(f"[{hostname}] Master 操作异常（可忽略）: {e}")
        finally:
            master_ssh.close()

        # Worker 节点本地 reset
        worker_ssh = SSHClient(
            host=ip,
            username=ssh_cfg.get("username", "root"),
            port=ssh_cfg.get("port", 22),
            password=ssh_cfg.get("password"),
            key_file=ssh_cfg.get("key_file"),
        )

        try:
            worker_ssh.connect()
            worker_ssh.exec_command(
                "kubeadm reset --force --cri-socket=unix:///var/run/containerd/containerd.sock 2>/dev/null || true",
                sudo=True, timeout=120
            )
            logger.info(f"[{hostname}] kubeadm reset 完成 ✓")

        except Exception as e:
            logger.warning(f"[{hostname}] Worker 回滚异常（可忽略）: {e}")
        finally:
            worker_ssh.close()

    logger.info("Node 加入回滚完成")
    state.set_global("node_join_completed", False)
