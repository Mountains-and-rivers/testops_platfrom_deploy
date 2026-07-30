#!/bin/bash
# ============================================================
# Nginx 卸载清理
# 用法: bash uninstall_nginx.sh [--data]
#   --data   含配置目录 /etc/nginx
# ============================================================
set -euo pipefail

REMOVE_DATA=false
[ "${1:-}" = "--data" ] && REMOVE_DATA=true

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  Nginx 卸载"
${REMOVE_DATA} && echo "  数据: 删除" || echo "  数据: 保留"
echo "============================================"

step "[1/4] 停止服务..."
systemctl stop nginx 2>/dev/null || true
pkill -9 nginx 2>/dev/null || true
rm -f /etc/systemd/system/nginx.service
systemctl daemon-reload 2>/dev/null || true
info "  服务已停止"

step "[2/4] 移除安装..."
rpm -e nginx 2>/dev/null && info "  RPM 已移除" || true
rm -rf /usr/local/nginx 2>/dev/null || true
rm -f /etc/yum.repos.d/nginx.repo 2>/dev/null || true
info "  安装目录已清理"

step "[3/4] 删除用户..."
userdel -r nginx 2>/dev/null && info "  nginx 用户已删除" || true

step "[4/4] 日志 + 配置..."
rm -rf /var/log/nginx /var/cache/nginx /tmp/build-cache/nginx-*.rpm /tmp/build-cache/nginx-*.tar.gz 2>/dev/null || true
if ${REMOVE_DATA}; then
    rm -rf /etc/nginx 2>/dev/null || true
    info "  /etc/nginx 已删除"
else
    info "  保留 /etc/nginx（--data 可删除）"
fi

echo ""
echo "============================================"
echo "  Nginx 卸载完成"
echo "============================================"
