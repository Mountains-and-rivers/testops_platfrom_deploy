#!/bin/bash
# ============================================================
# Redis 7 卸载清理
# 用法: bash uninstall_redis.sh [--data]
#   --data   含数据目录 /data/redis
# ============================================================
set -euo pipefail

REMOVE_DATA=false
[ "${1:-}" = "--data" ] && REMOVE_DATA=true

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  Redis 卸载"
${REMOVE_DATA} && echo "  数据: 删除" || echo "  数据: 保留"
echo "============================================"

step "[1/4] 停止服务..."
systemctl stop redis redis-sentinel 2>/dev/null || true
pkill -9 redis-server 2>/dev/null || true
rm -f /etc/systemd/system/redis.service
systemctl daemon-reload 2>/dev/null || true
info "  服务已停止"

step "[2/4] 移除安装..."
rpm -e redis 2>/dev/null && info "  RPM 已移除" || true
rm -rf /usr/local/redis 2>/dev/null || true
info "  安装目录已清理"

step "[3/4] 删除用户..."
userdel -r redis 2>/dev/null && info "  redis 用户已删除" || true

step "[4/4] 日志 + 数据..."
rm -rf /var/log/redis /tmp/build-cache/redis-*.rpm /tmp/build-cache/redis-*.tar.gz 2>/dev/null || true
if ${REMOVE_DATA}; then
    rm -rf /data/redis 2>/dev/null || true
    info "  /data/redis 已删除"
else
    info "  保留 /data/redis（--data 可删除）"
fi

echo ""
echo "============================================"
echo "  Redis 卸载完成"
echo "============================================"
