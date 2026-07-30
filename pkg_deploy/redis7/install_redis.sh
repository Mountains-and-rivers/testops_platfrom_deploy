#!/bin/bash
# ============================================================
# Redis 7.4.1 — 裸机单机部署（CentOS 9）
#
# 安装方式: 二进制 RPM（Remi）/ dnf 在线 / 源码编译（TODO）
# 包名:     redis-7.4.1-1.el9.remi.x86_64.rpm
# 本地优先: 脚本同目录 → /tmp/build-cache/
#
# 用法:     bash install_redis.sh [--port 6379] [--password Redis1@zendao2024]
# ============================================================
set -euo pipefail
cd /tmp

# ── 配置 ──
REDIS_VERSION="7.4.1"
REDIS_RPM="redis-${REDIS_VERSION}-1.el9.remi.x86_64.rpm"
REDIS_RPM_URL="https://rpms.remirepo.net/enterprise/9/remi/x86_64/${REDIS_RPM}"
REDIS_PASSWORD="${REDIS_PASSWORD:-Redis1@zendao2024}"
REDIS_PORT="${REDIS_PORT:-6379}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/redis}"
DATA_DIR="${DATA_DIR:-/data/redis}"
LOG_DIR="${LOG_DIR:-/var/log/redis}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) REDIS_PORT="$2"; shift 2 ;;
        --password) REDIS_PASSWORD="$2"; shift 2 ;;
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
echo "  Redis ${REDIS_VERSION} 单机部署（CentOS 9）"
echo "  方式: 二进制 RPM（Remi） |  端口: ${REDIS_PORT}"
echo "============================================"

# ═══ 0. 已安装检测 ═══
step "[0/6] 检查已安装..."
if [ -f "${INSTALL_DIR}/bin/redis-server" ]; then
    ver=$(${INSTALL_DIR}/bin/redis-server --version 2>&1 | awk '{print $3}' | cut -d= -f2)
    info "  已安装 Redis ${ver}（源码编译）"
    systemctl is-active redis &>/dev/null || systemctl start redis 2>/dev/null || true
    info "  跳过安装"; exit 0
fi
if rpm -q redis &>/dev/null 2>&1; then
    RPM_VER=$(rpm -q --qf "%{VERSION}" redis 2>/dev/null || echo "?")
    info "  已安装 Redis ${RPM_VER}（RPM）"
    systemctl is-active redis &>/dev/null || systemctl start redis 2>/dev/null || true
    info "  跳过安装"; exit 0
fi
systemctl stop redis redis-sentinel 2>/dev/null || true
pkill -9 redis-server 2>/dev/null || true; sleep 1

# ═══ 1. 安装 RPM ═══
step "[1/6] 安装 Redis..."

if pkg=$(get_local "${REDIS_RPM}"); then
    info "  使用本地: $(basename ${pkg}) ($(du -h ${pkg} | cut -f1))"
    cp "${pkg}" "/tmp/${REDIS_RPM}"
    rpm -ivh "/tmp/${REDIS_RPM}" 2>&1 || {
        warn "  rpm -ivh 失败，尝试 rpm -Uvh..."
        rpm -Uvh "/tmp/${REDIS_RPM}" 2>&1 || err "RPM 安装失败"
    }
    rm -f "/tmp/${REDIS_RPM}"
    # RPM 安装后 redis-server 在 /usr/bin/
    INSTALL_DIR="/usr"
elif command -v dnf &>/dev/null; then
    info "  本地 RPM 不存在，尝试 dnf 在线安装..."
    dnf install -y redis 2>&1 || {
        warn "  dnf 失败，尝试 Remi RPM..."
        info "  下载: ${REDIS_RPM_URL}"
        wget -q --show-progress -O "/tmp/${REDIS_RPM}" "${REDIS_RPM_URL}" 2>/dev/null \
            || curl -L -o "/tmp/${REDIS_RPM}" "${REDIS_RPM_URL}" \
            || err "下载失败，请手动下载放到 ${SCRIPT_DIR}/"
        rpm -ivh "/tmp/${REDIS_RPM}" 2>&1 || err "RPM 安装失败"
        rm -f "/tmp/${REDIS_RPM}"
    }
    INSTALL_DIR="/usr"
else
    err "无 dnf，请手动下载 redis RPM 放到 ${SCRIPT_DIR}/"
fi

# 验证
REDIS_BIN="${INSTALL_DIR}/bin/redis-server"
[ -f "${REDIS_BIN}" ] || REDIS_BIN=$(which redis-server 2>/dev/null || echo "")
[ -f "${REDIS_BIN}" ] || err "redis-server 未找到"
info "  ✓ Redis $(${REDIS_BIN} --version 2>&1 | head -1)"

# ═══ 2. 配置 ═══
step "[2/6] 配置..."

id redis &>/dev/null || { groupadd redis 2>/dev/null || true; useradd -r -g redis -s /bin/false redis 2>/dev/null || true; }
mkdir -p "${DATA_DIR}" "${LOG_DIR}"
chown -R redis:redis "${DATA_DIR}" "${LOG_DIR}"

# 配置文件写到 INSTALL_DIR（兼容源码和 RPM 两种路径）
cat > "${INSTALL_DIR}/redis.conf" << CONF
bind 0.0.0.0
port ${REDIS_PORT}
daemonize no
supervised systemd
pidfile /run/redis.pid
logfile "${LOG_DIR}/redis.log"
dir ${DATA_DIR}
databases 16
maxmemory 512mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
dbfilename dump.rdb
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
CONF
if [ -n "${REDIS_PASSWORD}" ]; then
    echo "requirepass ${REDIS_PASSWORD}" >> "${INSTALL_DIR}/redis.conf"
fi

# RPM 安装也同步配置
mkdir -p /etc/redis
cp "${INSTALL_DIR}/redis.conf" /etc/redis/redis.conf 2>/dev/null || true
chown -R redis:redis /etc/redis 2>/dev/null || true
info "  ✓ redis.conf"

# ═══ 3. systemd ═══
step "[3/6] 配置 systemd..."

cat > /etc/systemd/system/redis.service << SYSTEMDEOF
[Unit]
Description=Redis ${REDIS_VERSION}
After=network.target

[Service]
Type=notify
User=redis
Group=redis
ExecStart=${REDIS_BIN} ${INSTALL_DIR}/redis.conf --supervised systemd
ExecStop=${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} shutdown
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable redis
systemctl start redis
sleep 2
systemctl is-active redis &>/dev/null || {
    warn "  启动失败，查看日志: journalctl -u redis -n 30"
    err "Redis 启动失败"
}
info "  ✓ redis 已启动 + 开机自启"

# ═══ 4. 设置密码 ═══
step "[4/6] 设置密码..."

AUTH_CMD=""
[ -n "${REDIS_PASSWORD}" ] && AUTH_CMD="-a ${REDIS_PASSWORD} --no-auth-warning"

# 验证密码是否生效
if PING=$(${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} ${AUTH_CMD} ping 2>/dev/null); then
    if [ "${PING}" = "PONG" ]; then
        info "  ✓ 密码认证正常"
    fi
else
    warn "  密码认证异常（首次设置无密码则正常）"
fi
info "  ✓ 密码: ${REDIS_PASSWORD}"

# ═══ 5. 功能验证 ═══
step "[5/6] 功能验证..."

PASS=0

# 1) 进程
pgrep -x redis-server &>/dev/null && { info "  ✓ 进程运行中（PID $(pgrep -x redis-server | head -1)）"; PASS=$((PASS+1)); } \
    || warn "  ✗ 进程未运行"

# 2) 端口
if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${REDIS_PORT} " && { info "  ✓ 端口 ${REDIS_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${REDIS_PORT} 未监听"
fi

# 3) PING
PING=$(${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} ${AUTH_CMD} ping 2>/dev/null || echo "FAIL")
if [ "${PING}" = "PONG" ]; then
    info "  ✓ PING → PONG"
    PASS=$((PASS+1))
else
    warn "  ✗ PING 失败"
fi

# 4) SET/GET
if ${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} ${AUTH_CMD} --raw SET testops_deploy "ok" 2>/dev/null | grep -q OK; then
    GET=$(${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} ${AUTH_CMD} --raw GET testops_deploy 2>/dev/null)
    if [ "${GET}" = "ok" ]; then
        info "  ✓ SET/GET 正常"
        PASS=$((PASS+1))
    else
        warn "  ✗ GET 异常"
    fi
fi

# 防火墙
firewall-cmd --add-port=${REDIS_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

# ═══ 6. 完成 ═══
step "[6/6] 完成 ($(echo ${PASS}/4 项通过))"

# 进程状态
echo ""
echo "--- 服务状态 ---"
systemctl status redis --no-pager -l 2>/dev/null | head -5 || true
echo ""

# 账号信息
echo "============================================"
echo "  Redis ${REDIS_VERSION} 安装完成"
echo ""
echo "  ── 账号信息 ──"
echo "  密码:   ${REDIS_PASSWORD:-（无密码）}"
echo "  端口:   ${REDIS_PORT}"
echo ""
echo "  ── 连接命令 ──"
echo "  # 无密码连接"
echo "  redis-cli -h 127.0.0.1 -p ${REDIS_PORT}"
echo ""
echo "  # 密码连接"
echo "  redis-cli -h 127.0.0.1 -p ${REDIS_PORT} -a '${REDIS_PASSWORD}'"
echo ""
echo "  ── 管理命令 ──"
echo "  systemctl status redis"
echo "  systemctl {start|stop|restart} redis"
echo ""
echo "  卸载: bash uninstall_redis.sh"
echo "============================================"

# ═══════════════════════════════════════════════
# TODO: 源码编译模式（TLS 等高级选项）
#   - [ ] redis-${REDIS_VERSION}.tar.gz → make BUILD_TLS=yes → make install
#   - [ ] 参考: build_redis_source.sh (待实现)
# ═══════════════════════════════════════════════
