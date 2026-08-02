"""
K8s Cluster Deploy — 数据备份入口

备份集群关键数据：
- etcd 快照
- 集群证书 (PKI)
- kubeadm 配置文件
- 静态 Pod 清单
"""

import os
import sys
from datetime import datetime

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.yaml_helper import YAMLHelper
from common.ssh_client import SSHClient

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")
REPORTS_DIR = os.path.join(os.path.dirname(__file__), "..", "reports", "backup_files")


def run_backup():
    """
    执行 K8s 集群数据备份。

    备份内容：
    1. etcd 快照
    2. 集群证书（/etc/kubernetes/pki）
    3. kubeadm 配置文件
    """
    logger.info("=" * 60)
    logger.info("  K8s 集群数据备份开始")
    logger.info("=" * 60)

    # 加载配置
    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    backup_policy = YAMLHelper.load(os.path.join(CONFIG_DIR, "backup_policy.yaml"))
    policy = backup_policy.get("backup_policy", {})

    masters = node_list.get("node_list", {}).get("masters", [])
    if not masters:
        logger.error("未找到 Master 节点定义")
        sys.exit(1)

    master = masters[0]
    hostname = master["hostname"]
    ip = master["ip"]
    ssh_cfg = master.get("ssh", {})

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    local_backup_dir = os.path.join(REPORTS_DIR, f"backup_{timestamp}")
    os.makedirs(local_backup_dir, exist_ok=True)

    ssh = SSHClient(
        host=ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
    )

    try:
        ssh.connect()
        logger.info(f"连接到 Master 节点: {hostname} ({ip})")

        # 1. etcd 快照
        if policy.get("scope", {}).get("etcd_snapshot", True):
            etcd_cfg = policy.get("etcd", {})
            snapshot_dir = etcd_cfg.get("snapshot_dir", "/opt/testops/backup/etcd")
            snapshot_file = f"etcd-snapshot-{timestamp}.db"

            logger.info("创建 etcd 快照...")
            ssh.exec_command_ok(f"mkdir -p {snapshot_dir}", sudo=True)
            snapshot_path = f"{snapshot_dir}/{snapshot_file}"
            ssh.exec_command_ok(
                f"ETCDCTL_API=3 etcdctl snapshot save {snapshot_path} "
                f"--endpoints=https://127.0.0.1:2379 "
                f"--cacert=/etc/kubernetes/pki/etcd/ca.crt "
                f"--cert=/etc/kubernetes/pki/etcd/server.crt "
                f"--key=/etc/kubernetes/pki/etcd/server.key",
                sudo=True,
                timeout=60,
            )
            logger.info(f"etcd 快照已创建: {snapshot_path}")

            # 下载到本地
            ssh.download_file(snapshot_path, os.path.join(local_backup_dir, snapshot_file))
            logger.info(f"etcd 快照已下载到本地: {local_backup_dir}/{snapshot_file}")

        # 2. 集群证书
        if policy.get("scope", {}).get("certificates", True):
            cert_dir = policy.get("certificates", {}).get(
                "source_dir", "/etc/kubernetes/pki"
            )
            remote_tar = f"/tmp/k8s-pki-backup-{timestamp}.tar.gz"
            local_tar = os.path.join(local_backup_dir, f"pki-backup-{timestamp}.tar.gz")

            logger.info("备份集群证书...")
            ssh.exec_command_ok(f"tar -czf {remote_tar} -C /etc/kubernetes pki", sudo=True)
            ssh.download_file(remote_tar, local_tar)
            ssh.exec_command(f"rm -f {remote_tar}", sudo=True)
            logger.info(f"证书备份已保存: {local_tar}")

        # 3. kubeadm 配置
        if policy.get("scope", {}).get("kubeadm_config", True):
            logger.info("备份 kubeadm 配置...")
            config_files = [
                "/etc/kubernetes/kubeadm-config.yaml",
                "/etc/kubernetes/admin.conf",
            ]
            for cfg_file in config_files:
                try:
                    local_name = os.path.basename(cfg_file)
                    ssh.download_file(
                        cfg_file,
                        os.path.join(local_backup_dir, local_name),
                    )
                except Exception as e:
                    logger.warning(f"无法备份 {cfg_file}: {e}")

        logger.info(f"备份完成，本地目录: {local_backup_dir}")

    except Exception as e:
        logger.error(f"备份失败: {e}")
        raise

    finally:
        ssh.close()

    # 清理旧备份
    retention = policy.get("retention", {})
    if retention.get("auto_cleanup", True):
        max_backups = retention.get("max_backups", 30)
        # TODO: 实现按数量和时间的自动清理逻辑
        logger.debug(f"备份保留策略: 最多 {max_backups} 份")
