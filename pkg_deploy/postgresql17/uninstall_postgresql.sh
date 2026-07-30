#!/bin/bash
# ============================================================
# PostgreSQL 卸载清理（16/17 通用）
# 用法: bash uninstall_postgresql.sh [--data] [--ver 17]
#   --data   含数据目录 /data/postgresql + 删除 postgres 用户
# ============================================================
set -euo pipefail

PG_MAJOR="${PG_MAJOR:-17}"
REMOVE_DATA=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data) REMOVE_DATA=true ;;
        --ver)  PG_MAJOR="$2"; shift ;;
    esac
    shift
done

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  PostgreSQL ${PG_MAJOR} 卸载"
${REMOVE_DATA} && echo "  数据: 删除" || echo "  数据: 保留"
echo "============================================"

step "[1/5] 停止服务..."
# 所有可能的服务名
for svc in postgresql "postgresql-${PG_MAJOR}" "postgresql-16" "postgresql-17"; do
    systemctl stop "${svc}" 2>/dev/null && info "  ${svc} 已停止" || true
    systemctl disable "${svc}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service" "/usr/lib/systemd/system/${svc}.service" 2>/dev/null || true
done
# 清理所有 override 配置
rm -rf /etc/systemd/system/postgresql-*.service.d 2>/dev/null || true
# 清理 symlink
rm -f /etc/systemd/system/postgresql.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
pkill -9 postgres 2>/dev/null || true
sleep 2

step "[2/5] 移除 RPM..."
# 卸载所有可能的 PG RPM
for pkg in postgresql17-server postgresql17 postgresql17-libs \
           postgresql16-server postgresql16 postgresql16-libs; do
    rpm -e "${pkg}" 2>/dev/null && info "  ${pkg} 已移除" || true
done

step "[3/5] 清理安装目录..."
rm -rf /usr/pgsql-16 /usr/pgsql-17 /usr/local/postgresql 2>/dev/null || true
info "  安装目录已清理"

step "[4/5] 清理日志 & 缓存 & PID..."
rm -rf /var/log/postgresql /tmp/build-cache/postgresql*.rpm /tmp/build-cache/postgresql*.tar.gz 2>/dev/null || true
rm -f /data/postgresql/postmaster.pid /tmp/.s.PGSQL.* 2>/dev/null || true
info "  日志/缓存/PID 已清理"

step "[5/5] 数据目录 & 用户..."
if ${REMOVE_DATA}; then
    rm -rf /data/postgresql 2>/dev/null || true
    info "  /data/postgresql 已删除"
    userdel -r postgres 2>/dev/null && info "  postgres 用户已删除" || true
else
    info "  保留 /data/postgresql 和 postgres 用户（--data 可删除）"
fi

echo ""
echo "============================================"
echo "  PostgreSQL ${PG_MAJOR} 卸载完成"
echo "============================================"
