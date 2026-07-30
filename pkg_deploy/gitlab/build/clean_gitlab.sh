#!/bin/bash
# ============================================================
# GitLab CE 卸载清理
# 用法: bash clean_gitlab.sh [omnibus|docker|source] [--data]
#   --data   含数据目录 /data/gitlab
# ============================================================
set -euo pipefail

MODE="${1:-omnibus}"
REMOVE_DATA=false
GITLAB_HOME="${GITLAB_HOME:-/home/git}"

[ "${2:-}" = "--data" ] && REMOVE_DATA=true

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  GitLab CE 卸载"
echo "  模式: ${MODE}"
${REMOVE_DATA} && echo "  数据: 删除" || echo "  数据: 保留"
echo "============================================"

case "${MODE}" in
    omnibus)
        step "[1/4] 停止服务..."
        gitlab-ctl stop 2>/dev/null || true

        step "[2/4] 移除 RPM..."
        if command -v dnf &>/dev/null; then
            dnf remove -y gitlab-ce 2>/dev/null || true
        else
            dpkg --purge gitlab-ce 2>/dev/null || true
        fi
        info "RPM 已移除"

        step "[3/4] 清理目录..."
        rm -rf /opt/gitlab /var/opt/gitlab /etc/gitlab /var/log/gitlab 2>/dev/null || true
        ;;

    docker)
        step "[1/3] 停止容器..."
        docker rm -f gitlab 2>/dev/null || true

        step "[2/3] 删除镜像..."
        docker rmi -f gitlab/gitlab-ce 2>/dev/null || true
        ;;

    source)
        step "[1/4] 停止 systemd 服务..."
        for svc in gitlab-puma gitlab-sidekiq gitlab-workhorse gitlab-gitaly; do
            systemctl stop "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        done
        rm -f /etc/systemd/system/gitlab.target
        systemctl daemon-reload 2>/dev/null || true
        info "systemd 服务已移除"

        step "[2/4] 删除 GitLab 源码 & 编译产物..."
        rm -rf "${GITLAB_HOME}/gitlab" \
               "${GITLAB_HOME}/gitaly" \
               "${GITLAB_HOME}/gitlab-shell" \
               "${GITLAB_HOME}/gitlab-workhorse" \
               "${GITLAB_HOME}/gitlab-pages" \
               "${GITLAB_HOME}/repositories" \
               "${GITLAB_HOME}/.ssh" \
               /var/log/gitlab \
               2>/dev/null || true
        info "源码 & 编译产物已清理"

        step "[3/4] 清理数据库（保留 PostgreSQL 服务）..."
        su - postgres -c "psql -c \"DROP DATABASE IF EXISTS gitlabhq_production;\"" 2>/dev/null || true
        su - postgres -c "psql -c \"DROP USER IF EXISTS git;\"" 2>/dev/null || true
        info "数据库已清理"
        ;;

    *)
        echo "用法: bash clean_gitlab.sh [omnibus|docker|source] [--data]"
        exit 1
        ;;
esac

step "[4/4] 数据 + 临时文件..."
rm -rf /opt/build/gitlab /tmp/gitlab-* /tmp/gitaly-build /tmp/ruby-src 2>/dev/null || true

if ${REMOVE_DATA}; then
    rm -rf /data/gitlab 2>/dev/null || true
    info "/data/gitlab 已删除"
else
    info "保留 /data/gitlab（--data 可删除）"
fi

echo ""
echo "============================================"
echo "  GitLab CE 卸载完成"
echo "============================================"
