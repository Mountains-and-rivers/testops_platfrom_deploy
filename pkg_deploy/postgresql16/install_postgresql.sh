#!/bin/bash
# ============================================================
# PostgreSQL 16.8 — 裸机单机部署（CentOS 9）
#
# 安装方式: 二进制 RPM（PGDG 官方仓库）/ 源码编译（TODO）
# 包名:     postgresql16-{server,libs}-16.8-1PGDG.rhel9.x86_64.rpm
# 本地优先: 脚本同目录 → /tmp/build-cache/（3 个 rpm 缺一不可）
#
# 用法:     bash install_postgresql.sh [--port 5432] [--password Pg1@zendao2024]
# ============================================================
set -euo pipefail
cd /tmp

# ── 配置 ──
PG_VERSION="16.8"
PG_MAJOR="16"
PG_RPM_SERVER="postgresql${PG_MAJOR}-server-${PG_VERSION}-1PGDG.rhel9.x86_64.rpm"
PG_RPM_CLIENT="postgresql${PG_MAJOR}-${PG_VERSION}-1PGDG.rhel9.x86_64.rpm"
PG_RPM_LIBS="postgresql${PG_MAJOR}-libs-${PG_VERSION}-1PGDG.rhel9.x86_64.rpm"
PG_ROOT_PASSWORD='Pg1@zendao2024'
PG_DATABASE="zendao"
PG_PORT="${PG_PORT:-5432}"
INSTALL_DIR="/usr/pgsql-${PG_MAJOR}"                # RPM 安装路径
DATA_DIR="${DATA_DIR:-/data/postgresql}"             # 数据目录
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
echo "  PostgreSQL ${PG_VERSION} 单机部署（CentOS 9）"
echo "  方式: 二进制 RPM（PGDG） |  端口: ${PG_PORT}"
echo "  数据: ${DATA_DIR}"
echo "============================================"

# ═══ 0. 已安装检测 ═══
step "[0/6] 检查已安装..."
if [ -f "${INSTALL_DIR}/bin/postgres" ] && ${INSTALL_DIR}/bin/postgres --version &>/dev/null 2>&1; then
    ver=$(${INSTALL_DIR}/bin/postgres --version 2>&1 | awk '{print $3}')
    info "  已安装 PostgreSQL ${ver}"
    systemctl is-active postgresql &>/dev/null || systemctl start postgresql 2>/dev/null || true
    info "  跳过安装"; exit 0
fi
systemctl stop postgresql 2>/dev/null || true

# ═══ 1. 安装 RPM ═══
step "[1/6] 安装 RPM..."

RPM_LIST=("${PG_RPM_LIBS}" "${PG_RPM_CLIENT}" "${PG_RPM_SERVER}")
ALL_LOCAL=true
for rpm in "${RPM_LIST[@]}"; do
    if pkg=$(get_local "${rpm}"); then
        cp "${pkg}" "/tmp/${rpm}"
        info "  ✓ $(basename ${pkg})"
    else
        ALL_LOCAL=false
        break
    fi
done

if ${ALL_LOCAL}; then
    info "  全部本地就绪，开始安装..."
    rpm -ivh /tmp/${PG_RPM_LIBS} /tmp/${PG_RPM_CLIENT} /tmp/${PG_RPM_SERVER} 2>&1 || {
        warn "  rpm -ivh 失败，尝试 dnf localinstall..."
        dnf localinstall -y /tmp/${PG_RPM_LIBS} /tmp/${PG_RPM_CLIENT} /tmp/${PG_RPM_SERVER} 2>&1 || err "RPM 安装失败"
    }
    rm -f /tmp/${PG_RPM_LIBS} /tmp/${PG_RPM_CLIENT} /tmp/${PG_RPM_SERVER}
else
    PG_RPM_BASE="https://download.postgresql.org/pub/repos/yum/${PG_MAJOR}/redhat/rhel-9-x86_64"
    info "  本地 RPM 不完整，尝试 dnf 在线安装（3 个 RPM）..."
    dnf install -y \
        "${PG_RPM_BASE}/${PG_RPM_LIBS}" \
        "${PG_RPM_BASE}/${PG_RPM_CLIENT}" \
        "${PG_RPM_BASE}/${PG_RPM_SERVER}" 2>&1 || err "在线安装失败"
fi

# 验证
[ -f "${INSTALL_DIR}/bin/postgres" ] || err "安装失败: ${INSTALL_DIR}/bin/postgres 不存在"
info "  ✓ PostgreSQL $(${INSTALL_DIR}/bin/postgres --version 2>&1)"

# ═══ 2. 初始化数据库 ═══
step "[2/6] 初始化数据库..."

# PGDG RPM 会创建 postgres 用户（如果没有的话）
id postgres &>/dev/null || { groupadd postgres 2>/dev/null || true; useradd -r -g postgres -s /bin/bash postgres 2>/dev/null || true; }

mkdir -p "${DATA_DIR}" "${LOG_DIR}"
chown postgres:postgres "${DATA_DIR}" "${LOG_DIR}"

# 检查是否已初始化
if [ -f "${DATA_DIR}/PG_VERSION" ]; then
    info "  ✓ 数据目录已初始化，跳过 initdb"
else
    info "  执行 initdb..."
    su - postgres -c "${INSTALL_DIR}/bin/initdb -D ${DATA_DIR} --encoding=UTF8 --locale=en_US.UTF-8" 2>&1
    info "  ✓ initdb 完成"
fi

# 写入 postgresql.conf
cat > "${DATA_DIR}/postgresql.conf" << CONF
listen_addresses = '*'
port = ${PG_PORT}
max_connections = 200
shared_buffers = 256MB
logging_collector = on
log_directory = '${LOG_DIR}'
log_filename = 'postgresql-%a.log'
CONF

# 允许远程连接
grep -q "^host all all 0.0.0.0/0" "${DATA_DIR}/pg_hba.conf" 2>/dev/null \
    || echo "host all all 0.0.0.0/0 md5" >> "${DATA_DIR}/pg_hba.conf"
chown -R postgres:postgres "${DATA_DIR}"
info "  ✓ 配置完成"

# ═══ 3. systemd 服务 ═══
step "[3/6] 配置 systemd..."

# 先检查 RPM 自带的服务（postgresql-16.service），有则用，无则创建
RPM_SERVICE="/usr/lib/systemd/system/postgresql-${PG_MAJOR}.service"
if [ -f "${RPM_SERVICE}" ]; then
    # 修改 RPM 自带服务的数据目录指向我们的 DATA_DIR
    mkdir -p /etc/systemd/system/postgresql-${PG_MAJOR}.service.d
    cat > "/etc/systemd/system/postgresql-${PG_MAJOR}.service.d/override.conf" << OVERRIDE
[Service]
Environment=PGDATA=${DATA_DIR}
OVERRIDE
    systemctl daemon-reload
    systemctl enable "postgresql-${PG_MAJOR}"
    systemctl start "postgresql-${PG_MAJOR}"
    sleep 2
    if systemctl is-active "postgresql-${PG_MAJOR}" &>/dev/null; then
        SERVICE_NAME="postgresql-${PG_MAJOR}"
        info "  ✓ 使用 RPM 自带服务: ${SERVICE_NAME}"
    else
        warn "  RPM 自带服务启动失败，创建自定义服务..."
        systemctl stop "postgresql-${PG_MAJOR}" 2>/dev/null || true
        systemctl disable "postgresql-${PG_MAJOR}" 2>/dev/null || true
        CREATE_SERVICE=true
    fi
else
    CREATE_SERVICE=true
fi

if [ "${CREATE_SERVICE:-false}" = true ]; then
    cat > /etc/systemd/system/postgresql.service << SYSTEMDEOF
[Unit]
Description=PostgreSQL ${PG_VERSION}
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
Environment=PGDATA=${DATA_DIR}
ExecStart=${INSTALL_DIR}/bin/pg_ctl start -D ${DATA_DIR} -s -l ${LOG_DIR}/startup.log
ExecStop=${INSTALL_DIR}/bin/pg_ctl stop -D ${DATA_DIR} -s -m fast
ExecReload=${INSTALL_DIR}/bin/pg_ctl reload -D ${DATA_DIR} -s
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SYSTEMDEOF
    systemctl daemon-reload
    systemctl enable postgresql
    systemctl start postgresql
    sleep 2
    systemctl is-active postgresql &>/dev/null || {
        warn "  启动失败，查看日志: journalctl -u postgresql -n 30"
        err "PostgreSQL 启动失败"
    }
    SERVICE_NAME="postgresql"
fi
info "  ✓ ${SERVICE_NAME} 已启动 + 开机自启"

# ═══ 4. 设置密码 ═══
step "[4/6] 设置 postgres 密码..."

export PATH="${INSTALL_DIR}/bin:${PATH}"

# 先无密码 local 连接设置密码
su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_ROOT_PASSWORD}';\"" 2>/dev/null \
    && info "  ✓ postgres 密码已设置: ${PG_ROOT_PASSWORD}" \
    || { warn "  密码可能已设置，跳过"; }

# 创建默认数据库
su - postgres -c "psql -c \"CREATE DATABASE ${PG_DATABASE};\" 2>/dev/null" || true
info "  ✓ 数据库 ${PG_DATABASE} 已就绪"

# ═══ 5. 功能验证 ═══
step "[5/6] 功能验证..."

PASS=0

# 1) 进程
pgrep -x postgres &>/dev/null && { info "  ✓ 进程运行中（PID $(pgrep -x postgres | head -1)）"; PASS=$((PASS+1)); } \
    || warn "  ✗ 进程未运行"

# 2) 端口
if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${PG_PORT} " && { info "  ✓ 端口 ${PG_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${PG_PORT} 未监听"
fi

# 3) 本地连接
if su - postgres -c "psql -tAc 'SELECT 1'" 2>/dev/null | grep -q 1; then
    info "  ✓ 本地 socket 连接正常"
    PASS=$((PASS+1))
else
    warn "  ✗ 本地连接异常"
fi

# 4) TCP 连接（验证密码）
if PGPASSWORD="${PG_ROOT_PASSWORD}" ${INSTALL_DIR}/bin/psql -U postgres -h 127.0.0.1 -p ${PG_PORT} -tAc 'SELECT version();' 2>/dev/null | grep -q PostgreSQL; then
    info "  ✓ TCP 密码连接正常"
    PASS=$((PASS+1))
else
    warn "  ✗ TCP 连接异常"
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
echo "  安装:   ${INSTALL_DIR}"
echo "  数据:   ${DATA_DIR}"
echo "  服务:   systemctl status ${SERVICE_NAME}"
echo "  卸载:   bash uninstall_postgresql.sh"
echo "============================================"
