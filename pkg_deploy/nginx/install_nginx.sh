#!/bin/bash
# ============================================================
# Nginx 1.26.2 — 裸机单机部署（CentOS 9）
#
# 安装方式: 官方预编译二进制包（提取自 RPM）/ 源码编译（TODO）
# 原理:     下载官方 RPM → rpm2cpio 提取 → 手动部署
# 本地优先: 脚本同目录 nginx-*.rpm → /tmp/build-cache/
# 配置:     优先从脚本同目录读取 nginx.conf 模板
#
# 用法:     bash install_nginx.sh [--port 80] [--prefix /usr/local/nginx]
# ============================================================
set -euo pipefail
cd /tmp

# ── 配置 ──
NGINX_VERSION="1.26.2"
NGINX_RPM="nginx-${NGINX_VERSION}-1.el9.ngx.x86_64.rpm"
NGINX_RPM_URL="https://nginx.org/packages/centos/9/x86_64/RPMS/${NGINX_RPM}"
NGINX_USER="${NGINX_USER:-nginx}"
NGINX_PORT="${NGINX_PORT:-80}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/nginx}"
LOG_DIR="${LOG_DIR:-/var/log/nginx}"
CACHE_DIR="${CACHE_DIR:-/var/cache/nginx}"
RUN_DIR="${RUN_DIR:-/var/run}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)   NGINX_PORT="$2"; shift 2 ;;
        --prefix) INSTALL_DIR="$2"; shift 2 ;;
        --source) echo "源码编译模式 TODO，暂不支持"; exit 0 ;;
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
        # 通配匹配 nginx-*.rpm（兼容不同 build number）
        for f in "${d}"nginx-*.rpm; do
            [ -f "${f}" ] && [ -s "${f}" ] && { echo "${f}"; return 0; }
        done
    done
    return 1
}

echo "============================================"
echo "  Nginx ${NGINX_VERSION} 单机部署（CentOS 9）"
echo "  方式: 官方预编译二进制（rpm2cpio 提取）"
echo "  端口: ${NGINX_PORT}  |  用户: ${NGINX_USER}"
echo "  安装: ${INSTALL_DIR}"
echo "============================================"

# ═══ 0. 已安装检测 ═══
step "[0/5] 检查已安装..."

if [ -f "${INSTALL_DIR}/sbin/nginx" ]; then
    _ver=$(${INSTALL_DIR}/sbin/nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "?")
    info "  已安装 Nginx ${_ver}（${INSTALL_DIR}）"
    systemctl is-active nginx &>/dev/null || systemctl start nginx 2>/dev/null || true
    info "  跳过安装"; exit 0
fi

# 也检测 RPM 方式安装的 nginx
if rpm -q nginx &>/dev/null 2>&1; then
    RPM_VER=$(rpm -q --qf "%{VERSION}" nginx 2>/dev/null || echo "?")
    info "  已安装 Nginx ${RPM_VER}（RPM 方式，非本脚本安装，共存在所难免）"
fi

systemctl stop nginx 2>/dev/null || true
pkill -9 nginx 2>/dev/null || true; sleep 1

# ═══ 1. 获取 & 提取二进制 ═══
step "[1/5] 获取官方预编译二进制..."

# 1a. 获取 RPM 包
if _RPM=$(get_local "nginx-${NGINX_VERSION}"); then
    info "  使用本地: $(basename ${_RPM}) ($(du -h ${_RPM} | cut -f1))"
    cp "${_RPM}" "/tmp/${NGINX_RPM}"
else
    info "  下载官方 RPM: ${NGINX_RPM_URL}"
    for i in 1 2 3; do
        wget -q --show-progress -O "/tmp/${NGINX_RPM}" "${NGINX_RPM_URL}" 2>/dev/null \
            || curl -L -o "/tmp/${NGINX_RPM}" "${NGINX_RPM_URL}" \
            && break
        warn "  重试 (${i}/3)"; sleep 5
    done
    [ -f "/tmp/${NGINX_RPM}" ] && [ -s "/tmp/${NGINX_RPM}" ] || err "下载失败，请手动下载放到 ${SCRIPT_DIR}/"
    mkdir -p /tmp/build-cache && cp "/tmp/${NGINX_RPM}" "/tmp/build-cache/${NGINX_RPM}" 2>/dev/null || true
fi

# 1b. 提取 RPM 内容（不注册到 RPM 数据库）
info "  提取 RPM → ${INSTALL_DIR}..."
rm -rf /tmp/nginx-extract "${INSTALL_DIR}"
mkdir -p /tmp/nginx-extract "${INSTALL_DIR}"

# 安装 rpm2cpio + cpio（提取必需工具）
rpm -q rpm2cpio &>/dev/null || dnf install -y rpm2cpio 2>&1 | tail -3 || true
command -v cpio &>/dev/null || dnf install -y cpio 2>&1 | tail -3 || true

cd /tmp/nginx-extract
rpm2cpio "/tmp/${NGINX_RPM}" | cpio -idmv 2>&1 | tail -5 || err "RPM 提取失败"

# 1c. 迁移文件到 INSTALL_DIR
# RPM 内部结构: ./usr/sbin/nginx, ./usr/share/nginx/..., ./etc/nginx/..., ./var/log/nginx/...
# 合并到 /usr/local/nginx/ 下统一管理
for _src_dir in usr var etc; do
    if [ -d "${_src_dir}" ]; then
        cp -a "${_src_dir}"/* "${INSTALL_DIR}/" 2>/dev/null || true
    fi
done

# 整理：二进制放在 sbin/，配置放在 conf/（统一风格）
mkdir -p "${INSTALL_DIR}/sbin" "${INSTALL_DIR}/conf/conf.d"
# RPM 结构中 nginx 二进制在 usr/sbin/nginx，迁移到 sbin/
[ -f "${INSTALL_DIR}/sbin/nginx" ] || cp /tmp/nginx-extract/usr/sbin/nginx "${INSTALL_DIR}/sbin/nginx" 2>/dev/null || true
# mime.types 可能已存在于 INSTALL_DIR/share/nginx
[ -f "${INSTALL_DIR}/conf/mime.types" ] || cp /tmp/nginx-extract/usr/share/nginx/mime.types "${INSTALL_DIR}/conf/mime.types" 2>/dev/null || true
# 保留 RPM 自带的 conf 模板（备用）
if [ -d /tmp/nginx-extract/etc/nginx ] && [ ! -f "${INSTALL_DIR}/conf/nginx.conf.rpmorig" ]; then
    [ -f /tmp/nginx-extract/etc/nginx/nginx.conf ] && cp /tmp/nginx-extract/etc/nginx/nginx.conf "${INSTALL_DIR}/conf/nginx.conf.rpmorig" 2>/dev/null || true
fi

# 软链：全局可访问
ln -sf "${INSTALL_DIR}/sbin/nginx" /usr/sbin/nginx 2>/dev/null || true
ln -sf "${INSTALL_DIR}/sbin/nginx" /usr/local/bin/nginx 2>/dev/null || true

rm -rf /tmp/nginx-extract "/tmp/${NGINX_RPM}"
cd /tmp

_NGINX_BIN="${INSTALL_DIR}/sbin/nginx"
[ -f "${_NGINX_BIN}" ] || err "nginx 二进制未找到: ${_NGINX_BIN}"
info "  ✓ Nginx $(${_NGINX_BIN} -v 2>&1)"

# ═══ 2. 配置 ═══
step "[2/5] 配置..."

# 创建 nginx 用户
id ${NGINX_USER} &>/dev/null || { groupadd ${NGINX_USER} 2>/dev/null || true; useradd -r -g ${NGINX_USER} -s /bin/false ${NGINX_USER} 2>/dev/null || true; }

# 运行时目录
mkdir -p "${LOG_DIR}" "${CACHE_DIR}/client_temp" "${CACHE_DIR}/proxy_temp" \
    "${CACHE_DIR}/fastcgi_temp" "${CACHE_DIR}/uwsgi_temp" "${CACHE_DIR}/scgi_temp"
chown -R ${NGINX_USER}:${NGINX_USER} "${LOG_DIR}" "${CACHE_DIR}" 2>/dev/null || true

# 主配置：优先从脚本同目录读取模板
mkdir -p /etc/nginx/conf.d "${INSTALL_DIR}/conf/conf.d"

if [ -f "${SCRIPT_DIR}/nginx.conf" ]; then
    info "  使用本地模板: ${SCRIPT_DIR}/nginx.conf"
    cp "${SCRIPT_DIR}/nginx.conf" "${INSTALL_DIR}/conf/nginx.conf"
    # 替换模板变量
    sed -i "s|{{NGINX_USER}}|${NGINX_USER}|g"   "${INSTALL_DIR}/conf/nginx.conf"
    sed -i "s|{{NGINX_PORT}}|${NGINX_PORT}|g"   "${INSTALL_DIR}/conf/nginx.conf"
    sed -i "s|{{LOG_DIR}}|${LOG_DIR}|g"         "${INSTALL_DIR}/conf/nginx.conf"
    sed -i "s|{{CACHE_DIR}}|${CACHE_DIR}|g"     "${INSTALL_DIR}/conf/nginx.conf"
    sed -i "s|{{RUN_DIR}}|${RUN_DIR}|g"         "${INSTALL_DIR}/conf/nginx.conf"
else
    info "  无本地模板，生成默认配置..."
    cat > "${INSTALL_DIR}/conf/nginx.conf" << NGXCONF
user ${NGINX_USER};
worker_processes auto;
error_log ${LOG_DIR}/error.log warn;
pid ${RUN_DIR}/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
}

http {
    include       ${INSTALL_DIR}/conf/mime.types;
    default_type  application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log ${LOG_DIR}/access.log main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 65;
    client_max_body_size 250m;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml;

    include ${INSTALL_DIR}/conf/conf.d/*.conf;

    server {
        listen       ${NGINX_PORT};
        server_name  _;
        root         usr/share/nginx/html;
        index        index.html;

        location / {
            try_files \$uri \$uri/ =404;
        }
    }
}
NGXCONF
fi

chown -R ${NGINX_USER}:${NGINX_USER} "${INSTALL_DIR}/conf" 2>/dev/null || true
chown root:root "${INSTALL_DIR}/sbin/nginx" 2>/dev/null || true  # nginx 需要 root 绑定 1024↓ 端口

# 语法检查
${_NGINX_BIN} -t -c "${INSTALL_DIR}/conf/nginx.conf" 2>&1 || warn "  配置语法检查未通过"
info "  ✓ nginx.conf → ${INSTALL_DIR}/conf/nginx.conf"

# ═══ 3. systemd 服务 ═══
step "[3/5] 配置 systemd..."

cat > /etc/systemd/system/nginx.service << SYSTEMDEOF
[Unit]
Description=Nginx ${NGINX_VERSION} - high performance web server
After=network.target

[Service]
Type=forking
PIDFile=${RUN_DIR}/nginx.pid
ExecStartPre=${_NGINX_BIN} -t -c ${INSTALL_DIR}/conf/nginx.conf
ExecStart=${_NGINX_BIN} -c ${INSTALL_DIR}/conf/nginx.conf
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable nginx
systemctl start nginx
sleep 2
systemctl is-active nginx &>/dev/null || {
    warn "  启动失败，查看日志: journalctl -u nginx -n 30"
    err "Nginx 启动失败"
}
info "  ✓ nginx 已启动 + 开机自启"

# ═══ 4. 功能验证 ═══
step "[4/5] 功能验证..."

PASS=0

# 1) 进程
pgrep -x nginx &>/dev/null && { _PID=$(pgrep -x nginx | head -1); info "  ✓ 进程运行中（PID ${_PID}）"; PASS=$((PASS+1)); } \
    || warn "  ✗ 进程未运行"

# 2) 端口
if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${NGINX_PORT} " && { info "  ✓ 端口 ${NGINX_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${NGINX_PORT} 未监听"
fi

# 3) HTTP 响应
HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' --connect-timeout 3 "http://127.0.0.1:${NGINX_PORT}" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" != "000" ]; then
    info "  ✓ HTTP ${HTTP_CODE} (http://127.0.0.1:${NGINX_PORT})"
    PASS=$((PASS+1))
else
    warn "  ✗ HTTP 无响应"
fi

# 防火墙
firewall-cmd --add-service=http --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
firewall-cmd --add-service=https --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

# ═══ 5. 完成 ═══
step "[5/5] 完成 ($(echo ${PASS}/3 项通过))"

echo ""
echo "--- 服务状态 ---"
systemctl status nginx --no-pager -l 2>/dev/null | head -8 || true
echo ""

echo "============================================"
echo "  Nginx ${NGINX_VERSION} 安装完成"
echo ""
echo "  ── 基本信息 ──"
echo "  版本:     $(nginx -v 2>&1)"
echo "  来源:     官方预编译（rpm2cpio 提取自 nginx.org）"
echo "  用户:     ${NGINX_USER}"
echo "  端口:     ${NGINX_PORT}"
echo "  安装:     ${INSTALL_DIR}"
echo ""
echo "  ── 目录 ──"
echo "  配置:     ${INSTALL_DIR}/conf/nginx.conf"
echo "  子配置:   ${INSTALL_DIR}/conf/conf.d/"
echo "  日志:     ${LOG_DIR}/"
echo "  缓存:     ${CACHE_DIR}/"
echo "  HTML:     ${INSTALL_DIR}/share/nginx/html/"
echo ""
echo "  ── 管理命令 ──"
echo "  systemctl status nginx              # 查看状态"
echo "  systemctl {start|stop|restart|reload} nginx"
echo "  nginx -t                            # 配置语法检查"
echo "  nginx -s reload                     # 热重载"
echo "  journalctl -u nginx -f              # 实时日志"
echo ""
echo "  ── 安装方式 ──"
echo "  二进制提取: bash install_nginx.sh [--port PORT] [--prefix /usr/local/nginx]"
echo "  源码编译:   bash install_nginx.sh --source  →  TODO（预留）"
echo "  卸载:       bash uninstall_nginx.sh [--data]"
echo "============================================"

# ═══════════════════════════════════════════════
# TODO: 源码编译模式
#   - [ ] nginx-${NGINX_VERSION}.tar.gz → ./configure → make → make install
#   - [ ] ./configure --prefix=/usr/local/nginx \
#           --user=nginx --group=nginx \
#           --with-http_ssl_module --with-http_v2_module \
#           --with-stream --with-stream_ssl_module ...
#   - [ ] 参考: redis7 源码编译模式
# ═══════════════════════════════════════════════
