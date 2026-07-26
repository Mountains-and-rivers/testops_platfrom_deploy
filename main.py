#!/usr/bin/env python3
"""
TestOps Platform Deploy — 顶层统一 CLI 入口

提供多组件批量部署、卸载、健康检查、备份等顶层编排命令。
"""

import sys
import click

from common.logger import get_logger

logger = get_logger(__name__)

# 已注册的可部署组件清单
AVAILABLE_COMPONENTS = [
    "k8s_cluster_deploy",
    "zentao_deploy",
    "wikijs_deploy",
    "prometheus_stack_deploy",
    "metersphere_deploy",
    "ai_test_suite_deploy",
]


def validate_components(ctx, param, value):
    """校验用户输入的组件名称是否合法。"""
    if value is None:
        return value
    invalid = set(value) - set(AVAILABLE_COMPONENTS)
    if invalid:
        raise click.BadParameter(
            f"未知组件: {', '.join(invalid)}。"
            f"可用组件: {', '.join(AVAILABLE_COMPONENTS)}"
        )
    return value


@click.group()
@click.version_option(version="0.1.0", prog_name="TestOps Platform Deploy")
def cli():
    """TestOps Platform Deploy — 自动化测试运维平台部署工具。

    统一管理 K8s 集群部署、禅道、Wiki.js、Prometheus、MeterSphere 等组件的全生命周期。
    """


# ============================================================
# install — 安装命令
# ============================================================
@cli.command()
@click.option(
    "--all", "install_all", is_flag=True,
    help="安装全部组件（按依赖顺序）"
)
@click.option(
    "--components", "-c", multiple=True,
    callback=validate_components,
    help="指定要安装的组件（可多选，用空格分隔）"
)
@click.option(
    "--dry-run", is_flag=True,
    help="仅打印安装计划，不实际执行"
)
@click.option(
    "--force", "-f", is_flag=True,
    help="强制重新安装（跳过已安装状态检查）"
)
def install(install_all, components, dry_run, force):
    """安装指定组件或全平台安装。"""
    targets = list(AVAILABLE_COMPONENTS) if install_all else list(components)

    if not targets:
        click.echo("请使用 --all 或 --components 指定要安装的组件。")
        click.echo(f"可用组件: {', '.join(AVAILABLE_COMPONENTS)}")
        sys.exit(1)

    logger.info(f"安装目标组件: {targets}")

    if dry_run:
        click.echo("[DRY RUN] 安装计划（按依赖顺序）：")
        for i, comp in enumerate(targets, 1):
            click.echo(f"  {i}. {comp}")
        return

    # TODO: 调用编排层执行批量安装流水线
    click.echo(f"开始安装: {', '.join(targets)}")


# ============================================================
# uninstall — 卸载命令
# ============================================================
@cli.command()
@click.option("--all", "uninstall_all", is_flag=True, help="卸载全部组件（逆序）")
@click.option(
    "--components", "-c", multiple=True,
    callback=validate_components,
    help="指定要卸载的组件（可多选）"
)
@click.option("--dry-run", is_flag=True, help="仅打印卸载计划，不实际执行")
@click.option("--force", "-f", is_flag=True, help="强制卸载（跳过确认）")
def uninstall(uninstall_all, components, dry_run, force):
    """卸载指定组件或全平台卸载（逆依赖顺序）。"""
    targets = list(reversed(AVAILABLE_COMPONENTS)) if uninstall_all else list(components)

    if not targets:
        click.echo("请使用 --all 或 --components 指定要卸载的组件。")
        click.echo(f"可用组件: {', '.join(AVAILABLE_COMPONENTS)}")
        sys.exit(1)

    if not force and not dry_run:
        click.confirm(
            f"即将卸载以下组件: {', '.join(targets)}，确定继续？",
            abort=True
        )

    logger.info(f"卸载目标组件: {targets}")

    if dry_run:
        click.echo("[DRY RUN] 卸载计划（逆依赖顺序）：")
        for i, comp in enumerate(targets, 1):
            click.echo(f"  {i}. {comp}")
        return

    click.echo(f"开始卸载: {', '.join(targets)}")


# ============================================================
# check — 健康检查命令
# ============================================================
@cli.command()
@click.option("--all", "check_all", is_flag=True, help="检查全部组件")
@click.option(
    "--components", "-c", multiple=True,
    callback=validate_components,
    help="指定要检查的组件（可多选）"
)
@click.option("--output", "-o", type=click.Path(), help="检查报告输出路径")
def check(check_all, components, output):
    """对指定组件执行健康检查。"""
    targets = list(AVAILABLE_COMPONENTS) if check_all else list(components)

    if not targets:
        click.echo("请使用 --all 或 --components 指定要检查的组件。")
        sys.exit(1)

    logger.info(f"健康检查目标: {targets}")
    click.echo(f"开始健康检查: {', '.join(targets)}")

    if output:
        click.echo(f"报告将输出到: {output}")


# ============================================================
# backup — 备份命令
# ============================================================
@cli.command()
@click.option("--all", "backup_all", is_flag=True, help="备份全部组件")
@click.option(
    "--components", "-c", multiple=True,
    callback=validate_components,
    help="指定要备份的组件（可多选）"
)
def backup(backup_all, components):
    """备份指定组件的数据和配置。"""
    targets = list(AVAILABLE_COMPONENTS) if backup_all else list(components)

    if not targets:
        click.echo("请使用 --all 或 --components 指定要备份的组件。")
        sys.exit(1)

    logger.info(f"备份目标: {targets}")
    click.echo(f"开始备份: {', '.join(targets)}")


# ============================================================
# status — 状态查看命令
# ============================================================
@cli.command()
def status():
    """查看所有组件的部署状态。"""
    click.echo("组件部署状态：")
    for comp in AVAILABLE_COMPONENTS:
        # TODO: 读取各组件 workflow.state 获取真实状态
        click.echo(f"  {comp:<35} [未部署]")


# ============================================================
# version — 版本信息
# ============================================================
@cli.command()
def version():
    """查看平台及各组件版本信息。"""
    click.echo("TestOps Platform Deploy v0.1.0")
    click.echo("-" * 40)
    for comp in AVAILABLE_COMPONENTS:
        click.echo(f"  {comp:<35} v0.1.0")


if __name__ == "__main__":
    cli()
