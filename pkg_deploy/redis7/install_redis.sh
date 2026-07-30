#!/bin/bash
# ============================================================
# Redis 7.4.1 — 裸机单机部署（CentOS 9）
#
# 安装方式: 二进制 RPM / dnf 在线
# 本地优先: 脚本同目录 → /tmp/build-cache/（redis-*.rpm 通配匹配）
#
# 用法:     bash install_redis.sh [--port 6379] [--password Pg1@zendao2024]
# ============================================================
set -euo pipefail
cd /tmp

# ── 配置 ──
REDIS_VERSION="7.4.1"
# 本地 RPM 通配匹配（redis-*.rpm），不硬编码具体文件名
REDIS_OFFICIAL_RPM="https://rpm.redis.io/redis-${REDIS_VERSION}-1.el9.x86_64.rpm"
REDIS_PASSWORD="${REDIS_PASSWORD:-Pg1@zendao2024}"
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

# 查找所有可能的 redis-server 路径
_REDIS_BIN=""
for _c in "${INSTALL_DIR}/bin/redis-server" "/usr/bin/redis-server" "/usr/local/bin/redis-server"; do
    [ -x "${_c}" ] && { _REDIS_BIN="${_c}"; break; }
done
# 用 which 兜底
[ -z "${_REDIS_BIN}" ] && _REDIS_BIN=$(which redis-server 2>/dev/null || echo "")

_SKIP=false
if [ -n "${_REDIS_BIN}" ] && [ -x "${_REDIS_BIN}" ]; then
    _installed_ver=$(${_REDIS_BIN} --version 2>&1 | awk '{print $3}' | cut -d= -f2)
    info "  检测到 Redis ${_installed_ver} (${_REDIS_BIN})"

    # 版本比较：如果已安装版本 >= 目标版本，跳过
    _target_major=$(echo "${REDIS_VERSION}" | cut -d. -f1)
    _installed_major=$(echo "${_installed_ver}" | cut -d. -f1)
    if [ "${_installed_major}" -ge "${_target_major}" ] 2>/dev/null; then
        info "  已安装版本 >= ${REDIS_VERSION}，跳过安装"
        _SKIP=true
    else
        warn "  已安装版本 ${_installed_ver} < ${REDIS_VERSION}，覆盖安装"
        systemctl stop redis redis-sentinel 2>/dev/null || true
        pkill -9 redis-server 2>/dev/null || true; sleep 1
    fi
elif rpm -q redis &>/dev/null 2>&1; then
    RPM_VER=$(rpm -q --qf "%{VERSION}" redis 2>/dev/null || echo "?")
    _rpm_major=$(echo "${RPM_VER}" | cut -d. -f1)
    _target_major=$(echo "${REDIS_VERSION}" | cut -d. -f1)
    if [ "${_rpm_major}" -ge "${_target_major}" ] 2>/dev/null; then
        info "  已安装 Redis ${RPM_VER}（RPM），跳过安装"
        systemctl is-active redis &>/dev/null || systemctl start redis 2>/dev/null || true
        _SKIP=true
    else
        warn "  RPM 版本 ${RPM_VER} < ${REDIS_VERSION}，覆盖安装"
        systemctl stop redis redis-sentinel 2>/dev/null || true
        pkill -9 redis-server 2>/dev/null || true; sleep 1
    fi
fi

if ${_SKIP}; then
    info "  跳过安装"; exit 0
fi

systemctl stop redis redis-sentinel 2>/dev/null || true
pkill -9 redis-server 2>/dev/null || true; sleep 1

# ═══ 1. 安装 Redis ═══
step "[1/6] 安装 Redis..."

INSTALL_DIR="/usr"
LOCAL_RPM=$(ls "${SCRIPT_DIR}/"redis-*.rpm 2>/dev/null | head -1) || true

if [ -n "${LOCAL_RPM}" ] && [ -s "${LOCAL_RPM}" ]; then
    # ── 本地 RPM 优先 ──
    info "  使用本地: $(basename ${LOCAL_RPM}) ($(du -h ${LOCAL_RPM} | cut -f1))"
    rpm -ivh "${LOCAL_RPM}" 2>&1 || {
        warn "  rpm -ivh 失败，尝试 rpm -Uvh..."
        rpm -Uvh "${LOCAL_RPM}" 2>&1 || err "RPM 安装失败"
    }

elif command -v dnf &>/dev/null; then
    # ── dnf 在线安装 ──
    info "  本地 RPM 不存在，尝试 dnf 在线安装..."
    if dnf install -y redis 2>&1; then
        info "  ✓ dnf 安装完成"
    elif dnf module install -y redis:7 2>&1; then
        info "  ✓ dnf module redis:7 安装完成"
    else
        # ── 官方 Redis RPM 兜底 ──
        warn "  dnf 均失败，尝试官方 Redis RPM..."
        info "  下载: ${REDIS_OFFICIAL_RPM}"
        wget -q --show-progress -O "/tmp/redis.rpm" "${REDIS_OFFICIAL_RPM}" 2>/dev/null \
            || curl -L -o "/tmp/redis.rpm" "${REDIS_OFFICIAL_RPM}" \
            || err "下载失败，请手动下载 redis RPM 放到 ${SCRIPT_DIR}/"
        rpm -ivh "/tmp/redis.rpm" 2>&1 || err "RPM 安装失败"
        rm -f "/tmp/redis.rpm"
    fi

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

# ── 服务状态 ──
echo ""
echo "--- 服务状态 ---"
systemctl status redis --no-pager -l 2>/dev/null | head -5 || true
echo ""

# ── 账号 & 连接信息 ──
echo "============================================"
echo "  Redis ${REDIS_VERSION} 安装完成"
echo ""
echo "  ── 认证信息 ──"
echo "  Redis 为单密码认证（无用户名概念）"
echo "  密码:   ${REDIS_PASSWORD:-（无密码）}"
echo "  端口:   ${REDIS_PORT}"
echo ""
echo "  ── 连接命令 ──"
echo "  # 本地连接（无密码时）"
echo "  redis-cli"
echo ""
echo "  # TCP 密码连接"
echo "  redis-cli -h 127.0.0.1 -p ${REDIS_PORT} -a '${REDIS_PASSWORD}'"
echo ""
echo "  # 交互式（先连接再认证，密码不泄露在命令行）"
echo "  redis-cli -h 127.0.0.1 -p ${REDIS_PORT}"
echo "  > AUTH ${REDIS_PASSWORD}"
echo ""
echo "  ── 管理命令 ──"
echo "  systemctl status redis          # 查看状态"
echo "  systemctl {start|stop|restart} redis"
echo "  journalctl -u redis -f          # 查看日志"
echo "  redis-cli -p ${REDIS_PORT} -a '...' INFO server  # 查看运行信息"
echo ""
echo "  卸载: bash uninstall_redis.sh"
echo "============================================"

# ═══════════════════════════════════════════════
# TODO: 源码编译模式（TLS 等高级选项）
#   - [ ] redis-${REDIS_VERSION}.tar.gz → make BUILD_TLS=yes → make install
#   - [ ] 参考: build_redis_source.sh (待实现)
# ═══════════════════════════════════════════════
