#!/bin/bash
# ============================================================
# Redis 7.4.1 — 裸机单机部署
#
# 安装方式: 二进制 RPM（已实现） / 源码编译（TODO）
# 包名:     redis-7.4.1-1.el9.remi.x86_64.rpm（Remi RPM）
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
echo "  Redis ${REDIS_VERSION} 单机部署"
echo "  方式: 二进制 RPM  |  端口: ${REDIS_PORT}"
echo "  安装: ${INSTALL_DIR}"
echo "============================================"

# ═══ 0. 已安装检测 ═══
step "[0/6] 检查已安装..."
if [ -f "${INSTALL_DIR}/bin/redis-server" ]; then
    ver=$(${INSTALL_DIR}/bin/redis-server --version 2>&1 | awk '{print $3}' | cut -d= -f2)
    info "  已安装 Redis ${ver}"
    systemctl is-active redis &>/dev/null || systemctl start redis 2>/dev/null || true
    info "  跳过安装"; exit 0
fi

# 检查 RPM 安装
if rpm -q redis &>/dev/null 2>&1; then
    RPM_VER=$(rpm -q --qf "%{VERSION}" redis 2>/dev/null || echo "?")
    info "  已安装 Redis ${RPM_VER} (RPM)"
    systemctl is-active redis &>/dev/null || systemctl start redis 2>/dev/null || true
    info "  跳过安装"; exit 0
fi

systemctl stop redis redis-sentinel 2>/dev/null || true
pkill -9 redis-server 2>/dev/null || true; sleep 1

# ═══ 1. 获取二进制包 ═══
step "[1/6] 获取二进制包..."

USE_FAST_COMPILE=false

if pkg=$(get_local "${REDIS_RPM}"); then
    info "  使用本地 RPM: $(basename ${pkg})"
    cp "${pkg}" "/tmp/${REDIS_RPM}"
elif command -v dnf &>/dev/null; then
    # 尝试 EPEL/Remi dnf 安装
    info "  尝试 dnf 安装 redis..."
    if dnf install -y redis 2>&1 | tail -2; then
        info "  ✓ dnf 安装完成"
        # 确认二进制路径
        REDIS_BIN=$(which redis-server 2>/dev/null || echo "/usr/bin/redis-server")
        INSTALL_DIR=$(dirname "$(dirname "${REDIS_BIN}")")
        DNF_INSTALL=true
    else
        warn "  dnf 失败，尝试 Remi RPM..."
        USE_FAST_COMPILE=true
    fi
else
    USE_FAST_COMPILE=true
fi

# Remi RPM 下载失败 → 快速编译（Redis 源码仅 3.5MB，编译 2 分钟）
if ${USE_FAST_COMPILE} && [ -z "${DNF_INSTALL:-}" ]; then
    REDIS_SRC="redis-${REDIS_VERSION}.tar.gz"
    if pkg=$(get_local "${REDIS_SRC}"); then
        info "  使用本地源码: $(basename ${pkg})"
        cp "${pkg}" "/tmp/${REDIS_SRC}"
    else
        REDIS_SRC_URL="https://download.redis.io/releases/${REDIS_SRC}"
        info "  下载源码: ${REDIS_SRC_URL}"
        wget -q --show-progress -O "/tmp/${REDIS_SRC}" "${REDIS_SRC_URL}" 2>/dev/null \
            || curl -L -o "/tmp/${REDIS_SRC}" "${REDIS_SRC_URL}" \
            || err "下载失败，请手动下载放到 ${SCRIPT_DIR}/"
    fi
    info "  ✓ ${REDIS_SRC}（快速编译模式，约 2 分钟）"
fi

# ═══ 2. 安装 ═══
step "[2/6] 安装..."

if [ -n "${DNF_INSTALL:-}" ]; then
    info "  ✓ 已通过 dnf 安装"
elif [ -f "/tmp/${REDIS_RPM}" ]; then
    # RPM 安装
    rpm -ivh "/tmp/${REDIS_RPM}" 2>&1 | tail -3 || {
        warn "  rpm -ivh 失败，尝试 rpm -Uvh..."
        rpm -Uvh "/tmp/${REDIS_RPM}" 2>&1 | tail -3 || err "RPM 安装失败"
    }
    rm -f "/tmp/${REDIS_RPM}"
    REDIS_BIN=$(which redis-server 2>/dev/null || echo "/usr/bin/redis-server")
    INSTALL_DIR=$(dirname "$(dirname "${REDIS_BIN}")")
else
    # 快速源码编译
    command -v gcc &>/dev/null || { dnf install -y gcc make 2>/dev/null || true; }
    rm -rf /tmp/redis-src "${INSTALL_DIR}"
    mkdir -p /tmp/redis-src
    tar -xzf "/tmp/${REDIS_SRC}" -C /tmp/redis-src --strip-components=1
    cd /tmp/redis-src
    make -j$(nproc) 2>&1 | tail -2
    make install PREFIX="${INSTALL_DIR}" 2>&1 | tail -2
    cd /tmp; rm -rf /tmp/redis-src "/tmp/${REDIS_SRC}"
fi
info "  ✓ Redis $(${INSTALL_DIR}/bin/redis-server --version 2>&1 | head -1)"

# ═══ 3. 配置 ═══
step "[3/6] 配置..."

id redis &>/dev/null || { groupadd redis; useradd -r -g redis -s /bin/false redis; }
mkdir -p "${DATA_DIR}" "${LOG_DIR}"
chown -R redis:redis "${DATA_DIR}" "${LOG_DIR}"

# 配置文件（源码编译需要；RPM 安装已有 /etc/redis/redis.conf）
if [ ! -f /etc/redis/redis.conf ]; then
    mkdir -p /etc/redis
fi

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

# RPM 安装时，更新 systemd 指向的配置文件
[ -f /etc/redis/redis.conf ] && cp "${INSTALL_DIR}/redis.conf" /etc/redis/redis.conf
info "  ✓ redis.conf"

# ═══ 4. systemd ═══
step "[4/6] 配置 systemd..."

cat > /etc/systemd/system/redis.service << SYSTEMDEOF
[Unit]
Description=Redis ${REDIS_VERSION}
After=network.target

[Service]
Type=notify
User=redis; Group=redis
ExecStart=${INSTALL_DIR}/bin/redis-server ${INSTALL_DIR}/redis.conf
ExecStop=${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} shutdown
Restart=on-failure; RestartSec=5; LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable redis
systemctl start redis
sleep 2
systemctl is-active redis &>/dev/null || err "Redis 启动失败"
info "  ✓ 服务已启动"

# ═══ 5. 功能验证 ═══
step "[5/6] 功能验证..."

PASS=0

# 1) 进程检查
pgrep -x redis-server &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗ 进程未运行"

# 2) 端口检查
if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${REDIS_PORT} " && { info "  ✓ 端口 ${REDIS_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${REDIS_PORT} 未监听"
fi

# 3) PING 测试
AUTH_CMD=""
[ -n "${REDIS_PASSWORD}" ] && AUTH_CMD="-a ${REDIS_PASSWORD} --no-auth-warning"
PING=$(${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} ${AUTH_CMD} ping 2>/dev/null || echo "FAIL")
if [ "${PING}" = "PONG" ]; then
    info "  ✓ PING → PONG"
    PASS=$((PASS+1))
else
    warn "  ✗ PING 失败"
fi

# 4) SET/GET 测试
VAL=$(${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} ${AUTH_CMD} --raw SET testops_deploy "ok" 2>/dev/null || echo "")
if [ "${VAL}" = "OK" ]; then
    GET=$(${INSTALL_DIR}/bin/redis-cli -p ${REDIS_PORT} ${AUTH_CMD} --raw GET testops_deploy 2>/dev/null || echo "")
    [ "${GET}" = "ok" ] && { info "  ✓ SET/GET 正常"; PASS=$((PASS+1)); } || warn "  ✗ GET 异常"
else
    warn "  ✗ SET 异常"
fi

# 防火墙
firewall-cmd --add-port=${REDIS_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

# ═══ 6. 完成 ═══
step "[6/6] 完成 ($(echo ${PASS}/4 项通过))"
echo ""
echo "============================================"
echo "  Redis ${REDIS_VERSION} 安装完成"
echo "  连接:   redis-cli -h 127.0.0.1 -p ${REDIS_PORT}"
[ -n "${REDIS_PASSWORD}" ] && echo "  密码:   ${REDIS_PASSWORD}"
echo "  管理:   systemctl {start|stop|restart|status} redis"
echo "  卸载:   bash uninstall_redis.sh"
echo "============================================"

# ═══════════════════════════════════════════════
# TODO: 源码编译模式（精细化）
#   - [ ] redis-${REDIS_VERSION}.tar.gz → make BUILD_TLS=yes → make install
#   - [ ] 参考: build_redis_source.sh (待实现)
#   - 注意: 当前快速编译已可用，TODO 为增加 TLS 支持等高级编译选项
# ═══════════════════════════════════════════════
