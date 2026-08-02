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

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "config")


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

        # 预拉 Worker 必需镜像（优先本地 tar → 阿里云镜像源）
        logger.info(f"[{hostname}] 预拉 Worker 镜像...")
        # 获取 containerd sandbox 版本
        _, pause_ver, _ = ssh.exec_command(
            "grep sandbox_image /etc/containerd/config.toml 2>/dev/null | "
            "grep -oP 'pause:\\K[^\"]+' || echo '3.10'",
            timeout=5
        )
        pv = pause_ver.strip() or "3.10"
        kv = state.get_global("k8s_version")
        if not kv:
            _ver_cfg = YAMLHelper.load(os.path.join(CONFIG_DIR, "software_version.yaml"))
            kv = _ver_cfg.get("software_version", {}).get("kubernetes", {}).get("default", "1.32.13")
        # Worker 需要的所有 kube-system 镜像（coredns 版本与 kubeadm 1.32 内置一致）
        pre_pull_images = [
            f"registry.k8s.io/pause:{pv}",              # sandbox
            f"registry.k8s.io/kube-proxy:v{kv}",        # kube-proxy daemonset
            f"registry.k8s.io/coredns/coredns:v1.11.3",  # coredns deployment
        ]
        # 镜像加速源（兜底）
        MIRROR = "registry.cn-hangzhou.aliyuncs.com/google_containers"
        # 本地 images/ 目录
        local_images_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "images"
        )
        for img in pre_pull_images:
            img_short = img.split("/")[-1]  # e.g. pause:3.10, kube-proxy:v1.32.13
            tar_name = img_short.replace(":", "_") + ".tar"
            # 检查 containerd 是否已有
            _, check, _ = ssh.exec_command(
                f"ctr -n k8s.io image ls -q 2>/dev/null | grep -qF '{img}' && echo YES || echo NO",
                timeout=5
            )
            if check.strip() == "YES":
                logger.info(f"[{hostname}]   [OK] {img_short} 已存在")
                continue

            pulled = False
            # ---- 策略 A: 本地 tar 上传导入（优先，零网络依赖） ----
            local_tar = os.path.join(local_images_dir, tar_name)
            if os.path.exists(local_tar) and os.path.getsize(local_tar) > 10000:
                logger.info(f"[{hostname}]   [tar] 上传 {tar_name} ...")
                ssh.upload_file(local_tar, f"/tmp/{tar_name}")
                ec, _, err = ssh.exec_command(
                    f"ctr -n k8s.io image import /tmp/{tar_name} 2>&1", timeout=120
                )
                ssh.exec_command(f"rm -f /tmp/{tar_name}", timeout=5)
                if ec == 0:
                    pulled = True
                    logger.info(f"[{hostname}]   [OK] {img_short} 本地导入完成")
                else:
                    logger.warning(f"[{hostname}]   [FAIL] {img_short} 本地导入: {err.strip()[-120:]}")

            # ---- 策略 B: 远程镜像源拉取（兜底） ----
            if not pulled:
                flat_name = img_short.split(":")[0]
                tag = img_short.split(":")[-1]
                candidates = [f"{MIRROR}/{flat_name}:{tag}"]
                if "/" in img.replace("registry.k8s.io/", "").split(":")[0]:
                    candidates.insert(0, img.replace("registry.k8s.io", MIRROR))
                for i, candidate in enumerate(candidates):
                    logger.info(f"[{hostname}]   [pull] {candidate.split('/')[0]}...")
                    ec, _, pull_err = ssh.exec_command(
                        f"ctr -n k8s.io image pull {candidate} 2>&1", timeout=60
                    )
                    if ec == 0:
                        if candidate != img:
                            ssh.exec_command(
                                f"ctr -n k8s.io image tag {candidate} {img} && "
                                f"ctr -n k8s.io image remove {candidate}", timeout=10
                            )
                        logger.info(f"[{hostname}]   [OK] {img_short} 远程拉取完成")
                        pulled = True
                        break
                    else:
                        logger.debug(f"[{hostname}]   候选[{i+1}]: {pull_err.strip()[-100:]}")

            if not pulled:
                logger.error(f"[{hostname}]   [FAIL] {img_short} 全部方式失败！"
                             f"节点加入后 kubelet 将尝试直连 registry.k8s.io（国内大概率超时）")

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

        # 复制 admin.conf 到 Worker，使 kubectl 可用
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
            # 从 master 下载 admin.conf → 上传到 worker（SFTP，原子写入）
            admin_tmp = os.path.join(
                os.path.dirname(os.path.dirname(os.path.dirname(__file__))),
                "runtime", "temp_cache", f"admin_{hostname}.conf"
            )
            os.makedirs(os.path.dirname(admin_tmp), exist_ok=True)
            master_ssh.download_file("/etc/kubernetes/admin.conf", admin_tmp)
            ssh.exec_command("mkdir -p $HOME/.kube", sudo=False, timeout=5)
            ssh.upload_file(admin_tmp, "/root/.kube/config")
            os.remove(admin_tmp)
            logger.info(f"[{hostname}] kubectl 配置已同步 ~/.kube/config")

            # 打标签
            labels = worker.get("labels", {})
            if labels:
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
    state.require_stage_success("stage4_master_init")

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
                sudo=False, timeout=120
            )
            logger.info(f"[{hostname}] kubeadm reset 完成 ✓")

        except Exception as e:
            logger.warning(f"[{hostname}] Worker 回滚异常（可忽略）: {e}")
        finally:
            worker_ssh.close()

    logger.info("Node 加入回滚完成")
    state.set_global("node_join_completed", False)
