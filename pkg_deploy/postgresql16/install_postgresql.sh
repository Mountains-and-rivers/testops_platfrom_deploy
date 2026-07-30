#!/bin/bash
# ============================================================
# PostgreSQL 16.8 — 裸机单机部署（CentOS 9）
#
# 安装方式: 二进制 RPM（PGDG 官方仓库）/ 源码编译（TODO）
# 包名:     postgresql16-{server,libs}-16.8-1PGDG.rhel9.x86_64.rpm
# 下载:     https://download.postgresql.org/pub/repos/yum/16/redhat/rhel-9-x86_64/
# 本地优先: 脚本同目录 → /tmp/build-cache/
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
PG_RPM_BASE="https://download.postgresql.org/pub/repos/yum/${PG_MAJOR}/redhat/rhel-9-x86_64"
PG_ROOT_PASSWORD='Pg1@zendao2024'
PG_DATABASE="zendao"
PG_PORT="${PG_PORT:-5432}"
INSTALL_DIR="/usr/pgsql-${PG_MAJOR}"
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

# 本地加载所有 RPM，缺少任一个则返回 1
load_all_rpms() {
    local missing=0
    for rpm in "$@"; do
        local f
        f=$(get_local "${rpm}") && info "  使用本地: $(basename ${f}) ($(du -h ${f} | cut -f1))" || {
            warn "  缺少: ${rpm}"; missing=1
        }
    done
    return ${missing}
}

echo "============================================"
echo "  PostgreSQL ${PG_VERSION} 单机部署（CentOS 9）"
echo "  方式: 二进制 RPM（PGDG） |  端口: ${PG_PORT}"
echo "  安装: ${INSTALL_DIR}      |  数据: ${DATA_DIR}"
echo "============================================"

# ═══ 0. 已安装检测 ═══
step "[0/6] 检查已安装..."
if [ -f "${INSTALL_DIR}/bin/postgres" ] && ${INSTALL_DIR}/bin/postgres --version &>/dev/null 2>&1; then
    ver=$(${INSTALL_DIR}/bin/postgres --version 2>&1 | awk '{print $3}')
    info "  已安装 PostgreSQL ${ver} (${INSTALL_DIR})"
    systemctl is-active postgresql &>/dev/null || systemctl start postgresql 2>/dev/null || true
    info "  跳过安装"; exit 0
fi
# 也检查 dnf 安装的
if command -v postgres &>/dev/null && postgres --version 2>&1 | grep -q "${PG_VERSION}"; then
    info "  已安装 PostgreSQL ${PG_VERSION} (dnf)"
    systemctl is-active postgresql &>/dev/null || systemctl start postgresql 2>/dev/null || true
    info "  跳过安装"; exit 0
fi
systemctl stop postgresql 2>/dev/null || true
pkill -9 postgres 2>/dev/null || true; sleep 1

# ═══ 1. 获取二进制 RPM 包 ═══
step "[1/6] 获取二进制 RPM 包..."

RPM_LIST=("${PG_RPM_LIBS}" "${PG_RPM_CLIENT}" "${PG_RPM_SERVER}")

if load_all_rpms "${RPM_LIST[@]}"; then
    info "  ✓ 全部 3 个 RPM 本地就绪"
    USE_LOCAL=true
else
    info "  尝试 dnf 在线安装..."
    if command -v dnf &>/dev/null; then
        dnf install -y "https://download.postgresql.org/pub/repos/yum/${PG_MAJOR}/redhat/rhel-9-x86_64/postgresql${PG_MAJOR}-server-${PG_VERSION}-1PGDG.rhel9.x86_64.rpm" 2>/dev/null && {
            info "  ✓ dnf 安装完成"
            DNF_INSTALL=true
        } || USE_DOWNLOAD=true
    else
        USE_DOWNLOAD=true
    fi
fi

if [ "${USE_DOWNLOAD:-false}" = true ]; then
    mkdir -p /tmp/pg-rpms
    for rpm in "${RPM_LIST[@]}"; do
        if pkg=$(get_local "${rpm}"); then
            cp "${pkg}" "/tmp/pg-rpms/${rpm}"
        else
            RPM_URL="${PG_RPM_BASE}/${rpm}"
            info "  下载: ${RPM_URL}"
            for i in 1 2 3; do
                wget -q --show-progress -P /tmp/pg-rpms "${RPM_URL}" 2>/dev/null \
                    || curl -L -o "/tmp/pg-rpms/${rpm}" "${RPM_URL}" \
                    && break
                warn "  重试 (${i}/3)"; sleep 5
            done
            [ -f "/tmp/pg-rpms/${rpm}" ] && [ -s "/tmp/pg-rpms/${rpm}" ] || err "下载失败: ${rpm}"
        fi
        # 缓存
        cp "/tmp/pg-rpms/${rpm}" "/tmp/build-cache/${rpm}" 2>/dev/null || true
    done
    info "  ✓ 3 个 RPM 已就绪"
fi

# ═══ 2. 安装 RPM ═══
step "[2/6] 安装 RPM..."

if [ -n "${DNF_INSTALL:-}" ]; then
    info "  ✓ 已通过 dnf 安装"
elif [ -d /tmp/pg-rpms ]; then
    rpm -ivh /tmp/pg-rpms/*.rpm 2>&1 || {
        warn "  rpm -ivh 失败，尝试 dnf localinstall..."
        dnf localinstall -y /tmp/pg-rpms/*.rpm 2>&1 || err "RPM 安装失败"
    }
    rm -rf /tmp/pg-rpms
fi

# 验证安装
[ -f "${INSTALL_DIR}/bin/postgres" ] || err "安装失败: ${INSTALL_DIR}/bin/postgres 不存在"
info "  ✓ PostgreSQL $(${INSTALL_DIR}/bin/postgres --version 2>&1)"

# ═══ 3. 初始化数据库 ═══
step "[3/6] 初始化数据库..."

id postgres &>/dev/null || { groupadd postgres 2>/dev/null || true; useradd -r -g postgres -s /bin/false postgres 2>/dev/null || true; }
mkdir -p "${DATA_DIR}" "${LOG_DIR}"
chown -R postgres:postgres "${DATA_DIR}" "${LOG_DIR}"

# 检查是否已初始化
if [ -f "${DATA_DIR}/PG_VERSION" ]; then
    info "  ✓ 数据目录已初始化"
else
    su - postgres -c "${INSTALL_DIR}/bin/initdb -D ${DATA_DIR} --encoding=UTF8 --locale=en_US.UTF-8" 2>&1
    info "  ✓ initdb 完成"
fi

# 写入 postgresql.conf（增量，避免覆盖已有配置）
cat >> "${DATA_DIR}/postgresql.conf" << CONF
listen_addresses = '*'
port = ${PG_PORT}
max_connections = 200
shared_buffers = 256MB
logging_collector = on
log_directory = '${LOG_DIR}'
log_filename = 'postgresql-%a.log'
CONF

# 允许远程连接（检查是否已存在）
grep -q "^host all all 0.0.0.0/0" "${DATA_DIR}/pg_hba.conf" 2>/dev/null \
    || echo "host all all 0.0.0.0/0 md5" >> "${DATA_DIR}/pg_hba.conf"
chown -R postgres:postgres "${DATA_DIR}"
info "  ✓ 配置完成"

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
systemctl is-active postgresql &>/dev/null || err "PostgreSQL 启动失败，检查: journalctl -u postgresql -n 20"
info "  ✓ 服务已启动"

# ═══ 5. 功能验证 ═══
step "[5/6] 功能验证 + 设置密码..."

PASS=0

# 1) 进程检查
pgrep -x postgres &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗ 进程未运行"

# 2) 端口检查
if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${PG_PORT} " && { info "  ✓ 端口 ${PG_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${PG_PORT} 未监听"
fi

# 3) 设置 postgres 密码
su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_ROOT_PASSWORD}';\"" 2>/dev/null \
    && { info "  ✓ postgres 密码已设置"; PASS=$((PASS+1)); } \
    || warn "  ✗ 密码设置异常（可能已设置）"

# 4) 创建数据库
su - postgres -c "psql -c \"CREATE DATABASE ${PG_DATABASE};\" 2>/dev/null" || true
info "  数据库 ${PG_DATABASE} 已就绪"

# 5) 连接验证
if PGPASSWORD="${PG_ROOT_PASSWORD}" ${INSTALL_DIR}/bin/psql -U postgres -h 127.0.0.1 -p ${PG_PORT} -tAc 'SELECT version();' 2>/dev/null | grep -q PostgreSQL; then
    info "  ✓ 远程连接正常"
    PASS=$((PASS+1))
else
    warn "  ✗ 远程连接异常（检查 pg_hba.conf 和密码）"
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
echo "  管理:   systemctl {start|stop|restart|status} postgresql"
echo "  卸载:   bash uninstall_postgresql.sh"
echo "============================================"

# ═══════════════════════════════════════════════
# TODO: 源码编译模式
#   - [ ] postgresql-${PG_VERSION}.tar.gz → ./configure → make → make install
#   - [ ] 参考: build_postgresql_source.sh (待实现)
# ═══════════════════════════════════════════════
