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
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

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
        step "[1/7] 停止 systemd 服务..."
        for svc in gitlab-puma gitlab-sidekiq gitlab-workhorse gitlab-gitaly; do
            systemctl stop "${svc}" 2>/dev/null && info "  ${svc} 已停止" || true
            systemctl disable "${svc}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        done
        rm -f /etc/systemd/system/gitlab.target
        systemctl daemon-reload 2>/dev/null || true
        info "  systemd 单元已移除"

        step "[2/7] 清理 Nginx..."
        # 删除 GitLab 反代配置
        rm -f /usr/local/nginx/conf/conf.d/gitlab.conf 2>/dev/null || true
        rm -f /etc/nginx/conf.d/gitlab.conf 2>/dev/null || true

        # 如果 Nginx 是 GitLab 安装脚本自动安装的（无其他站点配置），则完全卸载
        _NGINX_REMAIN_CONF=0
        for _d in /usr/local/nginx/conf/conf.d /etc/nginx/conf.d; do
            [ -d "${_d}" ] && _NGINX_REMAIN_CONF=$((_NGINX_REMAIN_CONF + $(ls "${_d}"/*.conf 2>/dev/null | wc -l)))
        done
        if [ "${_NGINX_REMAIN_CONF}" -eq 0 ] || ${REMOVE_DATA}; then
            # 无其他站点或指定 --data：完全卸载 Nginx
            _NGINX_UNINSTALL="${_SCRIPT_DIR}/../../nginx/uninstall_nginx.sh"
            if [ -f "${_NGINX_UNINSTALL}" ]; then
                bash "${_NGINX_UNINSTALL}" --data 2>/dev/null && info "  ✓ Nginx 已完全卸载" || true
            else
                systemctl stop nginx 2>/dev/null || true
                systemctl disable nginx 2>/dev/null || true
                rm -f /etc/systemd/system/nginx.service
                rm -rf /usr/local/nginx 2>/dev/null || true
                userdel -r nginx 2>/dev/null || true
                rm -rf /var/log/nginx /var/cache/nginx 2>/dev/null || true
                systemctl daemon-reload 2>/dev/null || true
                info "  ✓ Nginx 已清理（手动）"
            fi
        else
            # 有其他站点使用 Nginx：仅重载，保留 Nginx
            systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
            info "  ✓ GitLab 反代配置已移除，Nginx 保留（${_NGINX_REMAIN_CONF} 个其他站点）"
        fi

        step "[3/7] 删除 GitLab 源码 & 编译产物..."
        rm -rf \
            "${GITLAB_HOME}/gitlab" \
            "${GITLAB_HOME}/gitaly" \
            "${GITLAB_HOME}/gitlab-shell" \
            "${GITLAB_HOME}/gitlab-workhorse" \
            "${GITLAB_HOME}/gitlab-pages" \
            "${GITLAB_HOME}/repositories" \
            2>/dev/null || true
        info "  gitlab / gitaly / gitlab-shell / workhorse / pages / repositories"

        step "[4/7] 删除语言运行时（Ruby / Go / Node）..."
        rm -rf /usr/local/ruby /usr/local/go 2>/dev/null || true
        # Node.js 散落在 /usr/local/{bin,lib,include,share}，仅清理由本脚本安装的
        rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/yarn /usr/local/bin/npx 2>/dev/null || true
        rm -rf /usr/local/lib/node_modules 2>/dev/null || true
        info "  Ruby /usr/local/ruby  |  Go /usr/local/go  |  Node /usr/local/bin/{node,npm,yarn}"

        step "[5/7] 清理目录 & 权限..."
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

        step "[6/7] 清理数据库 + 用户..."
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
step "[7] 公共临时文件..."
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
