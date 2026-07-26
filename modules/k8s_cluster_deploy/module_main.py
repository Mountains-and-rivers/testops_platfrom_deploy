#!/usr/bin/env python3
"""
K8s Cluster Deploy — 组件独立 CLI 入口

可脱离全局 CLI 单独调试运行。
"""

import sys
import os

# 将项目根目录加入 sys.path，确保可导入 common 包
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

import click

from common.logger import get_logger

logger = get_logger(__name__)


@click.group()
@click.version_option(version="0.1.0", prog_name="K8s Cluster Deploy")
def cli():
    """K8s Cluster Deploy — Kubernetes 集群自动化部署模块。"""


@cli.command()
@click.option("--stage", "-s", type=int, default=0, help="从指定阶段开始执行（默认 0）")
@click.option("--dry-run", is_flag=True, help="仅打印安装计划，不实际执行")
def install(stage, dry_run):
    """执行完整 K8s 集群部署流水线。"""
    logger.info(f"K8s 集群安装：起始阶段 = Stage {stage}")

    if dry_run:
        click.echo("[DRY RUN] K8s 集群部署计划：")
        stages = [
            "Stage 0: 环境预检扫描",
            "Stage 1: 系统标准化初始化",
            "Stage 2: 容器运行时安装 (containerd)",
            "Stage 3: K8s 组件安装 (kubeadm/kubectl/kubelet)",
            "Stage 4: Master 节点集群初始化",
            "Stage 5: Node 节点加入集群",
            "Stage 6: CNI 网络插件部署 (Calico)",
            "Stage 7: 集群部署后健康校验",
        ]
        for i, s in enumerate(stages):
            if i >= stage:
                click.echo(f"  → {s}")
            else:
                click.echo(f"     {s} [跳过]")
        return

    # TODO: 调用 src/install.py 执行实际安装
    from src.install import run_install
    run_install(start_stage=stage)


@cli.command()
def check():
    """执行环境预检扫描。"""
    logger.info("K8s 集群环境预检")
    # TODO: 调用 src/check.py 执行预检
    from src.check import run_check
    run_check()


@cli.command()
@click.option("--force", "-f", is_flag=True, help="强制卸载，跳过确认")
def uninstall(force):
    """完整卸载 K8s 集群。"""
    if not force:
        click.confirm("即将卸载 K8s 集群，此操作不可逆！确定继续？", abort=True)

    logger.info("K8s 集群卸载")
    # TODO: 调用 src/uninstall.py 执行卸载
    from src.uninstall import run_uninstall
    run_uninstall()


@cli.command()
def backup():
    """备份集群数据和配置。"""
    logger.info("K8s 集群数据备份")
    from src.backup import run_backup
    run_backup()


@cli.command()
def status():
    """查看集群部署状态。"""
    logger.info("查询部署状态")
    # TODO: 读取 runtime/workflow.state 获取实时状态
    click.echo("K8s 集群部署状态: [未部署]")


@cli.command()
def upgrade():
    """升级 K8s 集群版本（预留）。"""
    click.echo("版本升级功能开发中...")


@cli.command()
def rollback():
    """回滚 K8s 集群版本（预留）。"""
    click.echo("版本回滚功能开发中...")


if __name__ == "__main__":
    cli()
