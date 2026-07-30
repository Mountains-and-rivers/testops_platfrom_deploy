#!/bin/bash
# ============================================================
# Nginx 1.26.2 — 裸机单机部署
#
# 安装方式: 二进制 RPM（已实现） / 源码编译（TODO）
# 包名:     nginx-1.26.2-1.el9.ngx.x86_64.rpm
# 下载:     https://nginx.org/packages/centos/9/x86_64/RPMS/
# 本地优先: 脚本同目录 → /tmp/build-cache/
#
# 用法:     bash install_nginx.sh [--port 80]
# ============================================================
set -euo pipefail
cd /tmp

# ── 配置 ──
NGINX_VERSION="1.26.2"
NGINX_RPM="nginx-${NGINX_VERSION}-1.el9.ngx.x86_64.rpm"
NGINX_RPM_URL="https://nginx.org/packages/centos/9/x86_64/RPMS/${NGINX_RPM}"
NGINX_PORT="${NGINX_PORT:-80}"
LOG_DIR="${LOG_DIR:-/var/log/nginx}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) NGINX_PORT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ── UI ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

get_local() {
    for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do
        [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }
    done
    return 1
}

echo "============================================"
echo "  Nginx ${NGINX_VERSION} 单机部署"
echo "  方式: 二进制 RPM  |  端口: ${NGINX_PORT}"
echo "============================================"

# ═══ 0. 已安装检测 ═══
step "[0/6] 检查已安装..."

# 检查源码安装
if [ -f /usr/local/nginx/sbin/nginx ]; then
    ver=$(/usr/local/nginx/sbin/nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "?")
    info "  已安装 Nginx ${ver} (源码)"
    systemctl is-active nginx &>/dev/null || systemctl start nginx 2>/dev/null || true
    info "  跳过安装"; exit 0
fi

# 检查 RPM 安装
if rpm -q nginx &>/dev/null 2>&1; then
    RPM_VER=$(rpm -q --qf "%{VERSION}" nginx 2>/dev/null || echo "?")
    info "  已安装 Nginx ${RPM_VER} (RPM)"
    systemctl is-active nginx &>/dev/null || systemctl start nginx 2>/dev/null || true
    info "  跳过安装"; exit 0
fi

systemctl stop nginx 2>/dev/null || true

# ═══ 1. 获取二进制包 ═══
step "[1/6] 获取二进制 RPM..."

if pkg=$(get_local "${NGINX_RPM}"); then
    info "  使用本地: $(basename ${pkg}) ($(du -h ${pkg} | cut -f1))"
    cp "${pkg}" "/tmp/${NGINX_RPM}"
else
    info "  下载: ${NGINX_RPM_URL}"
    for i in 1 2 3; do
        wget -q --show-progress -O "/tmp/${NGINX_RPM}" "${NGINX_RPM_URL}" 2>/dev/null \
            || curl -L -o "/tmp/${NGINX_RPM}" "${NGINX_RPM_URL}" \
            && break
        warn "  重试 (${i}/3)"; sleep 5
    done
    [ -f "/tmp/${NGINX_RPM}" ] && [ -s "/tmp/${NGINX_RPM}" ] || err "下载失败，请手动下载放到 ${SCRIPT_DIR}/"
fi
mkdir -p /tmp/build-cache && cp "/tmp/${NGINX_RPM}" "/tmp/build-cache/${NGINX_RPM}" 2>/dev/null || true
info "  ✓ ${NGINX_RPM}"

# ═══ 2. 安装 ═══
step "[2/6] 安装 RPM..."

rpm -ivh "/tmp/${NGINX_RPM}" 2>&1 | tail -3 || {
    warn "  rpm -ivh 失败，尝试 rpm -Uvh..."
    rpm -Uvh "/tmp/${NGINX_RPM}" 2>&1 | tail -3 || err "RPM 安装失败"
}
rm -f "/tmp/${NGINX_RPM}"

# 确认安装路径
NGINX_BIN=$(which nginx 2>/dev/null || echo "/usr/sbin/nginx")
NGINX_CONF="/etc/nginx/nginx.conf"
info "  ✓ Nginx $(nginx -v 2>&1)"

# ═══ 3. 配置 ═══
step "[3/6] 配置..."

# 日志目录
mkdir -p "${LOG_DIR}"
chown -R nginx:nginx "${LOG_DIR}" 2>/dev/null || true

# 反向代理模板（放在 conf.d 下，默认禁用后缀）
cat > /etc/nginx/conf.d/reverse-proxy-template.conf.disabled << 'REVPROXY'
# ============================================================
# Nginx 反向代理模板
# 用法: cp 此文件去掉 .disabled 后缀，修改 proxy_pass 目标
# ============================================================
server {
    listen 80;
    server_name _;

    # 静态文件根目录（可选）
    root /usr/share/nginx/html;

    # 反向代理到后端应用（按需取消注释）
    # location / {
    #     proxy_pass         http://127.0.0.1:8080;
    #     proxy_set_header   Host              $host;
    #     proxy_set_header   X-Real-IP         $remote_addr;
    #     proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    #     proxy_set_header   X-Forwarded-Proto $scheme;
    #     proxy_read_timeout 300;
    #     proxy_connect_timeout 300;
    #     proxy_buffering    off;
    #     client_max_body_size 512m;
    # }
}
REVPROXY
info "  ✓ 反向代理模板: /etc/nginx/conf.d/reverse-proxy-template.conf.disabled"

# ═══ 4. systemd ═══
step "[4/6] 配置 systemd..."

# RPM 自带 service 文件，确认存在后 enable
if [ -f /usr/lib/systemd/system/nginx.service ]; then
    cp /usr/lib/systemd/system/nginx.service /etc/systemd/system/ 2>/dev/null || true
fi

systemctl daemon-reload
systemctl enable nginx
systemctl start nginx
sleep 2
systemctl is-active nginx &>/dev/null || { warn "nginx 启动异常，检查: journalctl -u nginx -n 30"; }
info "  ✓ systemd 服务已配置"

# ═══ 5. 功能验证 ═══
step "[5/6] 功能验证..."

PASS=0

# 1) 进程检查
pgrep -x nginx &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗ 进程未运行"

# 2) 端口检查
if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${NGINX_PORT} " && { info "  ✓ 端口 ${NGINX_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${NGINX_PORT} 未监听"
fi

# 3) HTTP 响应检查
HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' --connect-timeout 3 "http://127.0.0.1:${NGINX_PORT}" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" != "000" ]; then
    info "  ✓ HTTP ${HTTP_CODE} (http://127.0.0.1:${NGINX_PORT})"
    PASS=$((PASS+1))
else
    warn "  ✗ HTTP 无响应"
fi

# 4) 版本
info "  版本: $(nginx -v 2>&1)"

# 防火墙
firewall-cmd --add-service=http --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
firewall-cmd --add-service=https --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

# ═══ 6. 完成 ═══
step "[6/6] 完成 ($(echo ${PASS}/3 项通过))"
echo ""
echo "============================================"
echo "  Nginx ${NGINX_VERSION} 安装完成"
echo "  访问:   http://127.0.0.1:${NGINX_PORT}"
echo "  配置:   ${NGINX_CONF}"
echo "  日志:   ${LOG_DIR}/"
echo "  管理:   systemctl {start|stop|restart|reload|status} nginx"
echo "  卸载:   bash uninstall_nginx.sh"
echo ""
echo "  反向代理: 启用 /etc/nginx/conf.d/reverse-proxy-template.conf.disabled"
echo "============================================"

# ═══════════════════════════════════════════════
# TODO: 源码编译模式
#   - [ ] nginx-${NGINX_VERSION}.tar.gz → ./configure → make → make install
#   - [ ] 参考: build_nginx_source.sh (待实现)
# ═══════════════════════════════════════════════
