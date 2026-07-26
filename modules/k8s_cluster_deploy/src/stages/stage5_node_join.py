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
    )

    try:
        ssh.connect()
        logger.info(f"[{hostname}] 开始加入集群...")

        # 执行 join
        exit_code, stdout, stderr = ssh.exec_command(
            join_cmd, sudo=True, timeout=120
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
