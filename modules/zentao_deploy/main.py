#!/usr/bin/env python3
"""
zentao_deploy — 禅道开源版企业级 TestOps 自动化部署 CLI
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import click
from common.log_utils import get_logger, setup_stdout_encoding

setup_stdout_encoding()
logger = get_logger(__name__)


@click.group()
@click.version_option(version="1.0.0", prog_name="Zentao Deploy")
def cli():
    """ZenTao Deploy — 禅道开源版自动化部署工具"""


# ============================================================
# build — 源码构建镜像
# ============================================================
@cli.command()
@click.option("--version", "-v", default="21.2", help="禅道版本号")
@click.option("--push/--no-push", default=False, help="构建后推送 Harbor")
@click.option("--skip-pull", is_flag=True, help="跳过源码拉取")
def build(version, push, skip_pull):
    """从 CentOS Stream 9 源码构建禅道 Docker 镜像"""
    from modules.zentao.build.build_image import clone_source, build_image
    from common.yaml_render import YAMLHelper
    config = YAMLHelper.load(os.path.join("configs", "global.yaml"))
    registry = config.get("harbor", {}).get("url", "").replace("https://", "").replace("http://", "")
    project = config.get("harbor", {}).get("project", "testops")
    if not skip_pull:
        clone_source(version)
    build_image(version, registry, project, push=push)


# ============================================================
# deploy — 部署到 K8s
# ============================================================
@cli.command()
def deploy():
    """一键部署禅道到 Kubernetes"""
    from modules.zentao.workflow.install import install_zentao
    install_zentao()


# ============================================================
# destroy — 一键销毁
# ============================================================
@cli.command()
@click.option("--delete-pvc", is_flag=True, help="同时删除 PVC（数据永久丢失）")
@click.option("--force", "-f", is_flag=True, help="跳过确认")
def destroy(delete_pvc, force):
    """销毁 K8s 中禅道全部资源"""
    from modules.zentao.workflow.destroy import destroy_zentao
    destroy_zentao(delete_pvc=delete_pvc, force=force)


# ============================================================
# upgrade — 版本升级
# ============================================================
@cli.command()
@click.option("--version", "-v", required=True, help="目标版本号")
def upgrade(version):
    """滚动升级禅道版本"""
    from modules.zentao.workflow.upgrade import upgrade_zentao
    upgrade_zentao(version)


# ============================================================
# check — 健康检查
# ============================================================
@cli.command()
def check():
    """部署后健康检查"""
    from modules.zentao.verify.health_check import check_zentao_health
    ok = check_zentao_health()
    sys.exit(0 if ok else 1)


# ============================================================
# plugin — 插件管理
# ============================================================
@cli.group()
def plugin():
    """禅道插件管理"""

@plugin.command(name="install")
@click.argument("plugin_name")
def plugin_install(plugin_name):
    """在线安装插件"""
    from modules.zentao.plugin_mgr.plugin_operate import install_plugin_online
    install_plugin_online(plugin_name)

@plugin.command(name="install-offline")
@click.argument("zip_path")
def plugin_install_offline(zip_path):
    """离线安装插件（上传 zip 包到 PVC）"""
    from modules.zentao.plugin_mgr.plugin_operate import install_plugin_offline
    install_plugin_offline(zip_path)

@plugin.command(name="list")
def plugin_list():
    """列出已安装插件"""
    from modules.zentao.plugin_mgr.plugin_operate import list_plugins
    list_plugins()


# ============================================================
# full-deploy — 完整链路
# ============================================================
@cli.command()
@click.option("--version", "-v", default="21.2", help="禅道版本")
@click.option("--skip-build", is_flag=True, help="跳过镜像构建")
def full_deploy(version, skip_build):
    """完整部署：构建镜像 → 推送 Harbor → 部署 K8s → 健康检查"""
    from workflows.full_zentao_deploy import full_deploy
    full_deploy(version, skip_build)


if __name__ == "__main__":
    cli()
