#!/bin/bash
# ============================================================
# PostgreSQL 16 卸载清理
# 用法: bash uninstall_postgresql.sh [--data]
#   --data   含数据目录 /data/postgresql
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

step "[1/4] 停止服务..."
systemctl stop postgresql 2>/dev/null || true
pkill -9 postgres 2>/dev/null || true
rm -f /etc/systemd/system/postgresql.service
systemctl daemon-reload 2>/dev/null || true
info "  服务已停止"

step "[2/4] 删除安装目录..."
rm -rf /usr/local/postgresql 2>/dev/null || true
info "  安装目录已清理"

step "[3/4] 删除用户..."
userdel -r postgres 2>/dev/null && info "  postgres 用户已删除" || true

step "[4/4] 日志 + 数据..."
rm -rf /var/log/postgresql /tmp/build-cache/postgresql-*.tar.gz 2>/dev/null || true
if ${REMOVE_DATA}; then
    rm -rf /data/postgresql 2>/dev/null || true
    info "  /data/postgresql 已删除"
else
    info "  保留 /data/postgresql（--data 可删除）"
fi

echo ""
echo "============================================"
echo "  PostgreSQL 16 卸载完成"
echo "============================================"
