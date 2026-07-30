#!/bin/bash
# ============================================================
# GitLab CE 卸载清理
# 用法: bash clean_gitlab.sh [omnibus|docker|source] [--data]
#   --data   含数据目录（/data/gitlab + 数据库 + 用户）
# ============================================================
set -euo pipefail

MODE="${1:-omnibus}"
REMOVE_DATA=false
GITLAB_HOME="${GITLAB_HOME:-/home/git}"

[ "${2:-}" = "--data" ] && REMOVE_DATA=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  GitLab CE 卸载"
echo "  模式: ${MODE}"
${REMOVE_DATA} && echo "  数据: 全部删除" || echo "  数据: 保留（--data 可删除）"
echo "============================================"

case "${MODE}" in
    omnibus)
        # ── Omnibus RPM ──
        step "[1/5] 停止服务..."
        gitlab-ctl stop 2>/dev/null || true
        gitlab-ctl cleanse 2>/dev/null || true
        info "  GitLab 服务已停止"

        step "[2/5] 移除 RPM..."
        if command -v dnf &>/dev/null; then
            dnf remove -y gitlab-ce 2>/dev/null && info "  gitlab-ce RPM 已移除" || true
        else
            dpkg --purge gitlab-ce 2>/dev/null && info "  gitlab-ce DEB 已移除" || true
        fi

        step "[3/5] 清理 Omnibus 目录..."
        rm -rf /opt/gitlab /var/opt/gitlab /etc/gitlab /var/log/gitlab 2>/dev/null || true
        info "  /opt/gitlab /var/opt/gitlab /etc/gitlab /var/log/gitlab"
        ;;

    docker)
        # ── Docker 容器 ──
        step "[1/4] 停止容器..."
        docker stop gitlab 2>/dev/null || true
        docker rm -f gitlab 2>/dev/null && info "  gitlab 容器已删除" || true

        step "[2/4] 删除镜像..."
        docker rmi -f gitlab/gitlab-ce 2>/dev/null && info "  gitlab/gitlab-ce 镜像已删除" || true
        docker rmi -f "registry.cn-hangzhou.aliyuncs.com/ethanx/gitlab-ce" 2>/dev/null || true

        step "[3/4] 清理 Docker 数据卷..."
        if ${REMOVE_DATA}; then
            rm -rf /data/gitlab 2>/dev/null || true
            info "  /data/gitlab 已删除"
        fi
        ;;

    source)
        # ── 源码编译 ──
        step "[1/6] 停止 systemd 服务..."
        for svc in gitlab-puma gitlab-sidekiq gitlab-workhorse gitlab-gitaly; do
            systemctl stop "${svc}" 2>/dev/null && info "  ${svc} 已停止" || true
            systemctl disable "${svc}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        done
        rm -f /etc/systemd/system/gitlab.target
        systemctl daemon-reload 2>/dev/null || true
        info "  systemd 单元已移除"

        step "[2/6] 删除 GitLab 源码 & 编译产物..."
        rm -rf \
            "${GITLAB_HOME}/gitlab" \
            "${GITLAB_HOME}/gitaly" \
            "${GITLAB_HOME}/gitlab-shell" \
            "${GITLAB_HOME}/gitlab-workhorse" \
            "${GITLAB_HOME}/gitlab-pages" \
            "${GITLAB_HOME}/repositories" \
            2>/dev/null || true
        info "  gitlab / gitaly / gitlab-shell / workhorse / pages / repositories"

        step "[3/6] 删除语言运行时（Ruby / Go / Node）..."
        rm -rf /usr/local/ruby /usr/local/go 2>/dev/null || true
        # Node.js 散落在 /usr/local/{bin,lib,include,share}，仅清理由本脚本安装的
        rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/yarn /usr/local/bin/npx 2>/dev/null || true
        rm -rf /usr/local/lib/node_modules 2>/dev/null || true
        info "  Ruby /usr/local/ruby  |  Go /usr/local/go  |  Node /usr/local/bin/{node,npm,yarn}"

        step "[4/6] 清理目录 & 权限..."
        rm -rf \
            "${GITLAB_HOME}/.ssh" \
            /var/log/gitlab \
            /data/gitlab/uploads \
            /data/gitlab/artifacts \
            /data/gitlab/pages \
            /data/gitlab/registry \
            /data/gitlab/terraform_state \
            2>/dev/null || true
        info "  .ssh / var/log/gitlab / /data/gitlab/*"

        step "[5/6] 清理数据库 + 用户..."
        if ${REMOVE_DATA}; then
            # 数据库
            su - postgres -c "psql -c \"DROP DATABASE IF EXISTS gitlabhq_production;\"" 2>/dev/null \
                && info "  gitlabhq_production 数据库已删除" || true
            su - postgres -c "psql -c \"DROP USER IF EXISTS git;\"" 2>/dev/null \
                && info "  git 数据库用户已删除" || true

            # git 用户
            userdel -r git 2>/dev/null && info "  git 系统用户已删除" || true
        else
            info "  跳过数据库/用户清理（--data 可删除）"
        fi
        ;;

    *)
        echo "用法: bash clean_gitlab.sh [omnibus|docker|source] [--data]"
        echo ""
        echo "  omnibus   清理 RPM 安装"
        echo "  docker    清理 Docker 容器+镜像"
        echo "  source    清理源码编译（含 Ruby/Go/Node 运行时）"
        echo "  --data    同时清理数据目录 + 数据库 + git 用户"
        exit 1
        ;;
esac

# ── 公共清理 ──
step "[6] 公共临时文件..."
rm -rf \
    /opt/build/gitlab \
    /tmp/gitlab-* \
    /tmp/gitaly-build \
    /tmp/ruby-src \
    /tmp/redis-src \
    /tmp/nginx-src \
    /tmp/build-cache/gitlab-* \
    /tmp/build-cache/gitaly-* \
    /tmp/build-cache/gitlab-shell-* \
    /tmp/build-cache/gitlab-workhorse-* \
    /tmp/build-cache/gitlab-pages-* \
    2>/dev/null || true
info "  /opt/build/gitlab /tmp/gitlab-* /tmp/*-src /tmp/build-cache/gitlab*"

if ${REMOVE_DATA}; then
    rm -rf /data/gitlab 2>/dev/null && info "  /data/gitlab 已删除" || true
else
    info "  保留 /data/gitlab（--data 可删除）"
fi

echo ""
echo "============================================"
echo "  GitLab CE 卸载完成"
echo "============================================"
