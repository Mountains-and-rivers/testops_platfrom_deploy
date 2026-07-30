#!/bin/bash
# ============================================================
# PostgreSQL 16.8 — 裸机单机部署
#
# 安装方式: 二进制 tar.gz（已实现） / 源码编译（TODO）
# 包名:     postgresql-16.8-1-linux-x64-binaries.tar.gz
# 下载:     https://get.enterprisedb.com/postgresql/
# 本地优先: 脚本同目录 → /tmp/build-cache/
#
# 用法:     bash install_postgresql.sh [--port 5432] [--password Pg1@zendao2024]
# ============================================================
set -euo pipefail
cd /tmp

# ── 配置 ──
PG_VERSION="16.8"
PG_BIN="postgresql-${PG_VERSION}-1-linux-x64-binaries.tar.gz"
PG_BIN_URL="https://get.enterprisedb.com/postgresql/postgresql-${PG_VERSION}-1-linux-x64-binaries.tar.gz"
PG_ROOT_PASSWORD='Pg1@zendao2024'
PG_DATABASE="zendao"
PG_PORT="${PG_PORT:-5432}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/postgresql}"
DATA_DIR="${DATA_DIR:-/data/postgresql}"
LOG_DIR="${LOG_DIR:-/var/log/postgresql}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PG_PORT="$2"; shift 2 ;;
        --password) PG_ROOT_PASSWORD="$2"; shift 2 ;;
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
echo "  PostgreSQL ${PG_VERSION} 单机部署"
echo "  方式: 二进制 tar.gz  |  端口: ${PG_PORT}"
echo "  安装: ${INSTALL_DIR}  |  数据: ${DATA_DIR}"
echo "============================================"

# ═══ 0. 已安装检测 ═══
step "[0/6] 检查已安装..."
if [ -f "${INSTALL_DIR}/bin/postgres" ]; then
    ver=$(${INSTALL_DIR}/bin/postgres --version 2>&1 | awk '{print $3}')
    info "  已安装 PostgreSQL ${ver}"
    systemctl is-active postgresql &>/dev/null || systemctl start postgresql 2>/dev/null || true
    info "  跳过安装"; exit 0
fi
systemctl stop postgresql 2>/dev/null || true
pkill -9 postgres 2>/dev/null || true; sleep 1

# ═══ 1. 获取二进制包 ═══
step "[1/6] 获取二进制包..."

if pkg=$(get_local "${PG_BIN}"); then
    info "  使用本地: $(basename ${pkg}) ($(du -h ${pkg} | cut -f1))"
    cp "${pkg}" "/tmp/${PG_BIN}"
else
    info "  下载: ${PG_BIN_URL}"
    for i in 1 2 3; do
        wget -q --show-progress -O "/tmp/${PG_BIN}" "${PG_BIN_URL}" 2>/dev/null \
            || curl -L -o "/tmp/${PG_BIN}" "${PG_BIN_URL}" \
            && break
        warn "  重试 (${i}/3)"; sleep 5
    done
    [ -f "/tmp/${PG_BIN}" ] && [ -s "/tmp/${PG_BIN}" ] || err "下载失败，请手动下载放到 ${SCRIPT_DIR}/"
fi
mkdir -p /tmp/build-cache && cp "/tmp/${PG_BIN}" "/tmp/build-cache/${PG_BIN}" 2>/dev/null || true
info "  ✓ ${PG_BIN}"

# ═══ 2. 安装 ═══
step "[2/6] 安装..."

rm -rf /tmp/pg-bin "${INSTALL_DIR}"
mkdir -p /tmp/pg-bin
tar -xzf "/tmp/${PG_BIN}" -C /tmp/pg-bin --strip-components=1
mv /tmp/pg-bin "${INSTALL_DIR}"
rm -f "/tmp/${PG_BIN}"
info "  ✓ ${INSTALL_DIR}/bin/postgres ($(${INSTALL_DIR}/bin/postgres --version 2>&1))"

# ═══ 3. 初始化数据库 ═══
step "[3/6] 初始化数据库..."

id postgres &>/dev/null || { groupadd postgres; useradd -r -g postgres -s /bin/false postgres; }
mkdir -p "${DATA_DIR}" "${LOG_DIR}"
chown -R postgres:postgres "${DATA_DIR}" "${LOG_DIR}"

export PATH="${INSTALL_DIR}/bin:${PATH}"
su - postgres -c "${INSTALL_DIR}/bin/initdb -D ${DATA_DIR} --encoding=UTF8 --locale=en_US.UTF-8" 
# 写入 postgresql.conf
cat >> "${DATA_DIR}/postgresql.conf" << CONF
listen_addresses = '*'
port = ${PG_PORT}
max_connections = 200
shared_buffers = 256MB
logging_collector = on
log_directory = '${LOG_DIR}'
log_filename = 'postgresql-%a.log'
CONF

# 允许远程连接
echo "host all all 0.0.0.0/0 md5" >> "${DATA_DIR}/pg_hba.conf"
chown -R postgres:postgres "${DATA_DIR}"
info "  ✓ 初始化完成"

# ═══ 4. systemd ═══
step "[4/6] 配置 systemd..."

cat > /etc/systemd/system/postgresql.service << SYSTEMDEOF
[Unit]
Description=PostgreSQL ${PG_VERSION}
After=network.target

[Service]
Type=forking
User=postgres; Group=postgres
ExecStart=${INSTALL_DIR}/bin/pg_ctl start -D ${DATA_DIR} -l ${LOG_DIR}/startup.log
ExecStop=${INSTALL_DIR}/bin/pg_ctl stop -D ${DATA_DIR}
ExecReload=${INSTALL_DIR}/bin/pg_ctl reload -D ${DATA_DIR}
Restart=on-failure; RestartSec=5; LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable postgresql
systemctl start postgresql
sleep 2
systemctl is-active postgresql &>/dev/null || err "PostgreSQL 启动失败"
info "  ✓ 服务已启动"

# ═══ 5. 功能验证 ═══
step "[5/6] 功能验证..."

PASS=0

# 1) 进程检查
pgrep -x postgres &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗ 进程未运行"

# 2) 端口检查
if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${PG_PORT} " && { info "  ✓ 端口 ${PG_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${PG_PORT} 未监听"
fi

# 3) 数据库连接检查
su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_ROOT_PASSWORD}';\"" 2>/dev/null && PASS=$((PASS+1))
su - postgres -c "psql -c \"CREATE DATABASE ${PG_DATABASE};\" 2>/dev/null" || true

# 4) 连接验证
if su - postgres -c "psql -tAc 'SELECT version();'" 2>/dev/null | grep -q PostgreSQL; then
    info "  ✓ 数据库连接正常"
    PASS=$((PASS+1))
else
    warn "  ✗ 数据库连接异常"
fi

# 防火墙
firewall-cmd --add-port=${PG_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

# ═══ 6. 完成 ═══
step "[6/6] 完成 ($(echo ${PASS}/4 项通过))"
echo ""
echo "============================================"
echo "  PostgreSQL ${PG_VERSION} 安装完成"
echo "  连接:   psql -U postgres -h 127.0.0.1 -p ${PG_PORT}"
echo "  密码:   ${PG_ROOT_PASSWORD}"
echo "  数据库: ${PG_DATABASE}"
echo "  管理:   systemctl {start|stop|restart|status} postgresql"
echo "  卸载:   bash uninstall_postgresql.sh"
echo "============================================"

# ═══════════════════════════════════════════════
# TODO: 源码编译模式
#   - [ ] postgresql-${PG_VERSION}.tar.gz → ./configure → make → make install
#   - [ ] 参考: build_postgresql_source.sh (待实现)
# ═══════════════════════════════════════════════
