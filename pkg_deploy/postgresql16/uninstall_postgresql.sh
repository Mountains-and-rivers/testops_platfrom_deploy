#!/bin/bash
# ============================================================
# PostgreSQL 16 卸载清理
# 用法: bash uninstall_postgresql.sh [--data]
#   --data   含数据目录 /data/postgresql + 删除 postgres 用户
# ============================================================
set -euo pipefail

REMOVE_DATA=false
[ "${1:-}" = "--data" ] && REMOVE_DATA=true

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  PostgreSQL 16 卸载"
${REMOVE_DATA} && echo "  数据: 删除" || echo "  数据: 保留"
echo "============================================"

step "[1/5] 停止服务..."
# 两种可能的服务名
for svc in postgresql postgresql-16; do
    systemctl stop "${svc}" 2>/dev/null && info "  ${svc} 已停止" || true
    systemctl disable "${svc}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
done
# 清理 override 配置
rm -rf /etc/systemd/system/postgresql-16.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
pkill -9 postgres 2>/dev/null || true

step "[2/5] 移除 RPM..."
rpm -e postgresql16-server postgresql16 postgresql16-libs 2>/dev/null && info "  RPM 已移除" \
    || info "  RPM 可能已卸载，跳过"

step "[3/5] 清理安装目录..."
rm -rf /usr/pgsql-16 /usr/local/postgresql 2>/dev/null || true
info "  安装目录已清理"

step "[4/5] 清理日志 & 缓存..."
rm -rf /var/log/postgresql /tmp/build-cache/postgresql*.rpm /tmp/build-cache/postgresql*.tar.gz 2>/dev/null || true
info "  日志/缓存已清理"

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
echo "  PostgreSQL 16 卸载完成"
echo "============================================"
