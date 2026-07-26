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

# 将当前模块目录加入 sys.path，确保可导入 src 包
MODULE_DIR = os.path.dirname(os.path.abspath(__file__))
if MODULE_DIR not in sys.path:
    sys.path.insert(0, MODULE_DIR)

import click

from common.logger import get_logger, setup_stdout_encoding

# 确保 Windows GBK 终端下 Unicode（emoji / ✓ ✗ 等）正常输出
setup_stdout_encoding()

logger = get_logger(__name__)


# ============================================================
# 统一的错误处理装饰器
# ============================================================
def safe_run(func_name: str):
    """统一包装执行，捕获异常并输出清晰的中文错误信息。"""
    def decorator(fn):
        import functools
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            try:
                return fn(*args, **kwargs)
            except ModuleNotFoundError as e:
                click.echo(f"\n{'='*50}")
                click.echo(f"  ✗ 模块导入失败")
                click.echo(f"  命令: {func_name}")
                click.echo(f"  缺失模块: {e.name}")
                click.echo(f"  请检查: pip install -r requirements.txt")
                click.echo(f"{'='*50}")
                sys.exit(1)
            except FileNotFoundError as e:
                click.echo(f"\n{'='*50}")
                click.echo(f"  ✗ 配置文件未找到")
                click.echo(f"  命令: {func_name}")
                click.echo(f"  文件: {e.filename}")
                click.echo(f"  请先修改 config/*.yaml 配置")
                click.echo(f"{'='*50}")
                sys.exit(1)
            except Exception as e:
                click.echo(f"\n{'='*50}")
                click.echo(f"  ✗ 执行失败: {func_name}")
                click.echo(f"  错误类型: {type(e).__name__}")
                click.echo(f"  错误详情: {e}")
                click.echo(f"  日志位置: modules/k8s_cluster_deploy/runtime/logs/")
                click.echo(f"{'='*50}")
                sys.exit(1)
        return wrapper
    return decorator


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

    # 调用 src/install.py 执行实际安装
    from src.install import run_install
    # 未指定 --stage 时是一键安装，重置状态；指定 --stage 是断点续跑
    run_install(start_stage=stage, reset_state=(stage == 0))


@cli.command()
def check():
    """执行环境预检扫描。"""
    logger.info("K8s 集群环境预检")
    from src.check import run_check
    run_check()


@cli.command()
@click.option("--force", "-f", is_flag=True, help="强制卸载，跳过确认")
def uninstall(force):
    """完整卸载 K8s 集群。"""
    if not force:
        click.confirm("即将卸载 K8s 集群，此操作不可逆！确定继续？", abort=True)

    logger.info("K8s 集群卸载")
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
    from src.workflow.pipeline import K8sDeployPipeline
    pipeline = K8sDeployPipeline(workflow_type="install")
    pipeline.register_all_default_stages()
    summary = pipeline.get_status_summary()
    click.echo(summary)


@cli.command()
def upgrade():
    """升级 K8s 集群版本（预留）。"""
    click.echo("版本升级功能开发中...")


@cli.command()
def rollback():
    """回滚 K8s 集群版本（预留）。"""
    click.echo("版本回滚功能开发中...")


# ============================================================
# stage — 单独执行指定阶段
# ============================================================
@cli.command()
@click.argument("stage_num", type=int)
def stage(stage_num):
    """单独执行指定阶段（0-7），不执行其他阶段。

    示例：
        python module_main.py stage 0    # 仅环境预检
        python module_main.py stage 4    # 仅 Master 初始化
        python module_main.py stage 6    # 仅部署 CNI
    """
    if stage_num < 0 or stage_num > 7:
        click.echo(f"无效阶段编号: {stage_num}，有效范围 0-7")
        sys.exit(1)

    from src.workflow.pipeline import K8sDeployPipeline

    pipeline = K8sDeployPipeline(workflow_type="install")
    pipeline.register_all_default_stages()

    success = pipeline.run_stage(stage_num)

    if success:
        click.echo(f"✓ Stage {stage_num} 执行成功")
    else:
        click.echo(f"✗ Stage {stage_num} 执行失败")
        sys.exit(1)


# ============================================================
# uninstall-stage — 单独回滚/卸载指定阶段
# ============================================================
@cli.command()
@click.argument("stage_num", type=int)
@click.option("--force", "-f", is_flag=True, help="强制卸载，跳过确认")
def uninstall_stage(stage_num, force):
    """回滚/卸载指定阶段（1-6），清除该阶段做出的所有更改。

    回滚后该阶段及后续阶段状态重置为 PENDING，可从当前阶段继续安装。

    示例：
        python module_main.py uninstall-stage 4    # 回滚 Master 初始化
        python module_main.py uninstall-stage 2    # 卸载 containerd
        python module_main.py uninstall-stage 6    # 移除 Calico CNI
    """
    if stage_num < 1 or stage_num > 7:
        click.echo(f"无效阶段编号: {stage_num}。Stage 0 只读无需回滚。有效范围 1-7")
        sys.exit(1)

    if not force:
        click.confirm(
            f"即将回滚 Stage {stage_num}，该阶段的所有更改将被清除。\n"
            f"回滚后可从 Stage {stage_num} 继续安装。确定继续？",
            abort=True
        )

    from src.workflow.pipeline import K8sDeployPipeline

    pipeline = K8sDeployPipeline(workflow_type="install")
    pipeline.register_all_default_stages()

    success = pipeline.rollback_stage(stage_num)

    if success:
        click.echo(f"✓ Stage {stage_num} 回滚成功，可从 Stage {stage_num} 继续安装")
    else:
        click.echo(f"✗ Stage {stage_num} 回滚失败")
        sys.exit(1)


if __name__ == "__main__":
    cli()
