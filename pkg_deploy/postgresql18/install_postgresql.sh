#!/bin/bash
# ============================================================
# PostgreSQL 18.4 — 裸机单机部署（CentOS 9）
#
# 安装方式: 二进制 RPM（PGDG 官方仓库）/ 源码编译（TODO）
# 包名:     postgresql18-{server,libs,contrib}-18.4-1PGDG.rhel9.x86_64.rpm
# 本地优先: 脚本同目录 → /tmp/build-cache/（3+1 个 rpm 缺一不可）
#
# 用法:     bash install_postgresql.sh [--port 5432] [--password Pg1@zendao2024] [--bind '*'] [--for-gitlab]
# ============================================================
set -euo pipefail

# 必须在 cd 之前计算脚本目录，否则相对路径 $0 会解析到 /tmp
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)"
cd /tmp

# ── 配置 ──
PG_VERSION="18.4"
PG_MAJOR="18"
# RPM 文件名通配（兼容不同 build number 和 el9 子版本）
PG_RPM_SERVER="postgresql${PG_MAJOR}-server-${PG_VERSION}-*.rpm"
PG_RPM_CLIENT="postgresql${PG_MAJOR}-${PG_VERSION}-*.rpm"
PG_RPM_LIBS="postgresql${PG_MAJOR}-libs-${PG_VERSION}-*.rpm"
PG_RPM_CONTRIB="postgresql${PG_MAJOR}-contrib-${PG_VERSION}-*.rpm"  # GitLab 需要 btree_gist / pg_trgm
PG_ROOT_PASSWORD='Pg1@zendao2024'
PG_DATABASE="zendao"
PG_PORT="${PG_PORT:-5432}"
PG_BIND="${PG_BIND:-*}"
FOR_GITLAB=false                                         # --for-gitlab
INSTALL_DIR="/usr/pgsql-${PG_MAJOR}"                # RPM 安装路径
DATA_DIR="${DATA_DIR:-/data/postgresql}"             # 数据目录
LOG_DIR="${LOG_DIR:-/var/log/postgresql}"

usage() {
    cat << 'USAGE'
用法: bash install_postgresql.sh [选项]

PostgreSQL 18.4 单机部署（CentOS 9 / RHEL 9）

选项:
  -h, --help           显示此帮助信息
  --port PORT          监听端口                     (默认: 5432)
  --password PASS      postgres 用户密码            (默认: Pg1@zendao2024)
  --bind ADDR          监听地址，* 表示所有网卡     (默认: *)
  --for-gitlab         GitLab 专用模式：
                         - 安装 postgresql18-contrib 扩展包
                         - 创建 pg_trgm / btree_gist / plpgsql 扩展
                         - 创建 git 用户 + gitlabhq_production 数据库

示例:
  bash install_postgresql.sh                                    # 基础安装
  bash install_postgresql.sh --port 5433 --password MyP@ss      # 自定义端口密码
  bash install_postgresql.sh --for-gitlab                       # GitLab 一键安装
  bash install_postgresql.sh --for-gitlab --password GitP@ss1   # GitLab + 自定义密码
  bash install_postgresql.sh --bind 127.0.0.1                   # 仅本地监听

环境变量:
  PG_PORT, PG_BIND, DATA_DIR, LOG_DIR

本地离线包（脚本同目录）:
  postgresql18-libs-18.4-2PGDG.rhel9.8.x86_64.rpm
  postgresql18-18.4-2PGDG.rhel9.8.x86_64.rpm
  postgresql18-server-18.4-2PGDG.rhel9.8.x86_64.rpm
  postgresql18-contrib-18.4-2PGDG.rhel9.8.x86_64.rpm   (GitLab 模式需要)
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --port) PG_PORT="$2"; shift 2 ;;
        --password) PG_ROOT_PASSWORD="$2"; shift 2 ;;
        --bind) PG_BIND="$2"; shift 2 ;;
        --for-gitlab) FOR_GITLAB=true; shift ;;
        *) echo "未知参数: $1，使用 -h 查看帮助"; exit 1 ;;
    esac
done

# ── UI ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ $0:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

get_local() {
    for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do
        # 支持通配符匹配（如 postgresql18-libs-18.4-*.rpm）
        local found
        found=$(ls "${d}"$1 2>/dev/null | head -1) || true
        if [ -n "${found}" ] && [ -s "${found}" ]; then
            echo "${found}"
            return 0
        fi
    done
    return 1
}

echo "============================================"
echo "  PostgreSQL ${PG_VERSION} 单机部署（CentOS 9）"
echo "  方式: 二进制 RPM（PGDG） |  端口: ${PG_PORT}"
echo "  绑定: ${PG_BIND} (远程连接已开启) |  数据: ${DATA_DIR}"
${FOR_GITLAB} && echo "  用途: GitLab（将安装 contrib 扩展 + 创建 git 用户和库）"
echo "============================================"

# ═══ 0. 已安装检测 ═══
step "[0/6] 检查已安装..."
# 只有在二进制存在、数据目录有效、服务能启动时才跳过
# 但 --for-gitlab 模式下，即使 PG 已安装，仍需检查 contrib 包
if [ -f "${INSTALL_DIR}/bin/postgres" ] && ${INSTALL_DIR}/bin/postgres --version &>/dev/null \
    && [ -f "${DATA_DIR}/PG_VERSION" ]; then
    ver=$(${INSTALL_DIR}/bin/postgres --version 2>&1 | awk '{print $3}')
    info "  已安装 PostgreSQL ${ver}"
    systemctl is-active postgresql &>/dev/null || systemctl is-active "postgresql-${PG_MAJOR}" &>/dev/null \
        || systemctl start postgresql 2>/dev/null || systemctl start "postgresql-${PG_MAJOR}" 2>/dev/null || true
    if ${FOR_GITLAB}; then
        info "  --for-gitlab 模式，检查 contrib 和 GitLab 初始化..."
    else
        info "  跳过安装"; exit 0
    fi
else
    systemctl stop postgresql 2>/dev/null || true
    systemctl stop "postgresql-${PG_MAJOR}" 2>/dev/null || true
    # 清理旧 PID 防止 "already running" 错误
    rm -f "${DATA_DIR}/postmaster.pid" 2>/dev/null || true
fi

# ═══ 1. 安装 RPM ═══
step "[1/6] 安装 RPM..."

# 检测 stale RPM 状态：RPM 数据库认为已安装但文件缺失
# （可能因卸载脚本 kill 后残留造成）
for _pkg in postgresql${PG_MAJOR} postgresql${PG_MAJOR}-libs postgresql${PG_MAJOR}-server; do
    if rpm -q "${_pkg}" &>/dev/null && [ ! -f "${INSTALL_DIR}/bin/postgres" ]; then
        warn "  检测到 ${_pkg} RPM 残留（文件缺失），强制清理..."
        rpm -e --nodeps postgresql${PG_MAJOR}-server postgresql${PG_MAJOR} postgresql${PG_MAJOR}-libs 2>/dev/null || true
        break
    fi
done

# 清理可能残留的 dnf/yum 锁（上次 Ctrl+C 中断导致）
pkill -9 dnf 2>/dev/null || true
rm -f /var/lib/rpm/.rpm.lock /var/cache/dnf/*/lock* 2>/dev/null || true

# 优先本地 RPM（脚本同目录 → /tmp/build-cache → ./ → $HOME），无则在线 dnf
_LOCAL_LIBS=$(get_local "${PG_RPM_LIBS}") || true
_LOCAL_CLIENT=$(get_local "${PG_RPM_CLIENT}") || true
_LOCAL_SERVER=$(get_local "${PG_RPM_SERVER}") || true

if [ -n "${_LOCAL_LIBS}" ] && [ -n "${_LOCAL_CLIENT}" ] && [ -n "${_LOCAL_SERVER}" ]; then
    info "  ✓ 本地 RPM 就绪，安装..."
    rpm -Uvh "${_LOCAL_LIBS}" "${_LOCAL_CLIENT}" "${_LOCAL_SERVER}" 2>&1 || true
    if [ ! -f "${INSTALL_DIR}/bin/postgres" ]; then
        warn "  rpm -Uvh 未成功，尝试 dnf localinstall..."
        dnf localinstall -y "${_LOCAL_LIBS}" "${_LOCAL_CLIENT}" "${_LOCAL_SERVER}" 2>&1 || true
    fi
else
    info "  本地 RPM 不完整，尝试 dnf 在线安装..."
    dnf install -y postgresql${PG_MAJOR}-server postgresql${PG_MAJOR} postgresql${PG_MAJOR}-libs 2>&1 || true
fi

# 最终验证
if [ ! -f "${INSTALL_DIR}/bin/postgres" ]; then
    err "安装失败: ${INSTALL_DIR}/bin/postgres 不存在（请检查网络或本地 RPM 包）"
fi

[ -f "${INSTALL_DIR}/bin/postgres" ] || err "安装失败: ${INSTALL_DIR}/bin/postgres 不存在"
info "  ✓ PostgreSQL $(${INSTALL_DIR}/bin/postgres --version 2>&1)"

# ── 1.5 安装 contrib 扩展包（GitLab 需要 btree_gist / pg_trgm）──
if ${FOR_GITLAB}; then
    step "[1.5/6] 安装 contrib 扩展包（GitLab 需要）..."
    _CONTRIB_INSTALLED=false

    # 检查 btree_gist.so 是否已存在
    for _so in "${INSTALL_DIR}/lib/btree_gist.so" "/usr/pgsql-${PG_MAJOR}/lib/btree_gist.so"; do
        [ -f "${_so}" ] && _CONTRIB_INSTALLED=true && break
    done

    if ${_CONTRIB_INSTALLED}; then
        info "  ✓ contrib 扩展已安装"
    else
        # 优先本地 RPM，无则在线安装
        _LOCAL_CONTRIB=$(get_local "${PG_RPM_CONTRIB}") || true
        if [ -n "${_LOCAL_CONTRIB}" ]; then
            info "  ✓ 本地 contrib RPM 就绪: ${_LOCAL_CONTRIB}"
            rpm -Uvh "${_LOCAL_CONTRIB}" 2>&1 || dnf localinstall -y "${_LOCAL_CONTRIB}" 2>&1 || true
        else
            info "  在线安装 postgresql${PG_MAJOR}-contrib..."
            dnf install -y "postgresql${PG_MAJOR}-contrib" 2>&1 || true
        fi

        # 验证安装
        for _so in "${INSTALL_DIR}/lib/btree_gist.so" "/usr/pgsql-${PG_MAJOR}/lib/btree_gist.so"; do
            [ -f "${_so}" ] && _CONTRIB_INSTALLED=true && break
        done
        ${_CONTRIB_INSTALLED} && info "  ✓ postgresql${PG_MAJOR}-contrib 安装完成" \
            || warn "  ✗ contrib 安装失败，请手动安装: dnf install -y postgresql${PG_MAJOR}-contrib"
    fi
fi

# ═══ 2. 初始化数据库 ═══
step "[2/6] 初始化数据库..."

# PGDG RPM 会创建 postgres 用户（如果没有的话）
id postgres &>/dev/null || { groupadd postgres 2>/dev/null || true; useradd -r -g postgres -s /bin/bash postgres 2>/dev/null || true; }

mkdir -p "${DATA_DIR}" "${LOG_DIR}" 2>/dev/null || true
chown postgres:postgres "${DATA_DIR}" "${LOG_DIR}" 2>/dev/null || true
# 确保父目录可写
chmod 750 "${DATA_DIR}" 2>/dev/null || true

# 检查是否已初始化（版本不匹配则重建）
if [ -f "${DATA_DIR}/PG_VERSION" ]; then
    EXISTING_VER=$(cat "${DATA_DIR}/PG_VERSION")
    if [ "${EXISTING_VER}" != "${PG_MAJOR}" ]; then
        warn "  数据目录为 PG ${EXISTING_VER} 格式，PG ${PG_MAJOR} 不兼容，重建..."
        rm -rf "${DATA_DIR}"
        mkdir -p "${DATA_DIR}"
        chown postgres:postgres "${DATA_DIR}"
    else
        info "  ✓ 数据目录已初始化 (PG ${PG_MAJOR})，跳过 initdb"
    fi
fi
if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
    info "  执行 initdb..."
    su - postgres -c "${INSTALL_DIR}/bin/initdb -D ${DATA_DIR} --encoding=UTF8 --locale=en_US.UTF-8" 2>&1
    info "  ✓ initdb 完成"
fi

# 写入 postgresql.conf（覆盖默认，确保远程连接和端口正确）
cat > "${DATA_DIR}/postgresql.conf" << CONF
listen_addresses = '${PG_BIND}'
port = ${PG_PORT}
max_connections = 200
shared_buffers = 256MB
logging_collector = on
log_directory = '${LOG_DIR}'
log_filename = 'postgresql-%a.log'
CONF

# 允许远程连接（pg_hba.conf）
grep -q "^host all all 0.0.0.0/0" "${DATA_DIR}/pg_hba.conf" 2>/dev/null \
    || echo "host all all 0.0.0.0/0 md5" >> "${DATA_DIR}/pg_hba.conf"
chown -R postgres:postgres "${DATA_DIR}"
info "  ✓ 配置完成"

# ═══ 3. systemd 服务 ═══
step "[3/6] 配置 systemd..."

# 先检查 RPM 自带的服务（postgresql-18.service），有则用，无则创建
RPM_SERVICE="/usr/lib/systemd/system/postgresql-${PG_MAJOR}.service"
if [ -f "${RPM_SERVICE}" ]; then
    # 修改 RPM 自带服务的数据目录指向我们的 DATA_DIR
    mkdir -p /etc/systemd/system/postgresql-${PG_MAJOR}.service.d
    cat > "/etc/systemd/system/postgresql-${PG_MAJOR}.service.d/override.conf" << OVERRIDE
[Service]
Environment=PGDATA=${DATA_DIR}
[Install]
Alias=postgresql.service
OVERRIDE
    systemctl daemon-reload
    systemctl enable "postgresql-${PG_MAJOR}"
    systemctl start "postgresql-${PG_MAJOR}"
    sleep 2
    if systemctl is-active "postgresql-${PG_MAJOR}" &>/dev/null; then
        SERVICE_NAME="postgresql"
        info "  ✓ RPM 服务已启动 (别名: postgresql)"
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

# ── 4.5 GitLab 数据库初始化 ──
if ${FOR_GITLAB}; then
    step "[4.5/6] GitLab 数据库初始化..."

    # 创建 GitLab 所需的扩展（在 template1 中，新建库自动继承）
    info "  创建扩展: pg_trgm, btree_gist, plpgsql..."
    su - postgres -c "psql -d template1 -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'" 2>/dev/null || true
    su - postgres -c "psql -d template1 -c 'CREATE EXTENSION IF NOT EXISTS btree_gist;'" 2>/dev/null || true
    su - postgres -c "psql -d template1 -c 'CREATE EXTENSION IF NOT EXISTS plpgsql;'" 2>/dev/null || true

    # 验证 btree_gist 扩展
    if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_available_extensions WHERE name='btree_gist'\"" 2>/dev/null | grep -q 1; then
        info "  ✓ btree_gist 扩展可用"
    else
        warn "  ✗ btree_gist 扩展不可用，请确认 postgresql${PG_MAJOR}-contrib 已安装并重启 PG"
    fi

    # 创建 git 用户（GitLab 数据库 owner）
    info "  创建 git 用户..."
    su - postgres -c "psql -c \"CREATE USER git CREATEDB;\"" 2>/dev/null || true
    su - postgres -c "psql -c \"ALTER USER git WITH PASSWORD '${PG_ROOT_PASSWORD}';\"" 2>/dev/null || true
    info "  ✓ git 用户已创建（密码同 postgres: ${PG_ROOT_PASSWORD}）"

    # 创建 gitlabhq_production 数据库
    DB_EXISTS=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='gitlabhq_production'\"" 2>/dev/null || echo "0")
    if [ "${DB_EXISTS}" = "1" ]; then
        info "  ✓ gitlabhq_production 数据库已存在"
    else
        su - postgres -c "psql -c 'CREATE DATABASE gitlabhq_production OWNER git;'" 2>/dev/null || true
        info "  ✓ gitlabhq_production 数据库已创建 (owner: git)"
    fi
fi

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

# 进程状态
echo ""
echo "--- 服务状态 ---"
systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null | head -5 || true
echo ""

# 账号信息
echo "============================================"
echo "  PostgreSQL ${PG_VERSION} 安装完成"
${FOR_GITLAB} && echo "  用途: GitLab 数据库"
echo ""
echo "  ── 账号信息 ──"
echo "  用户名: postgres"
echo "  密码:   ${PG_ROOT_PASSWORD}"
echo "  数据库: ${PG_DATABASE}"
echo "  绑定地址: ${PG_BIND} (远程连接已开启)"
if ${FOR_GITLAB}; then
    echo ""
    echo "  ── GitLab 数据库 ──"
    echo "  git 用户: git / ${PG_ROOT_PASSWORD}"
    echo "  数据库:   gitlabhq_production (owner: git)"
    echo "  扩展:     pg_trgm, btree_gist, plpgsql"
fi
echo ""
echo "  ── 连接命令 ──"
echo "  # 本地 socket 连接（免密）"
echo "  sudo -u postgres psql"
echo ""
echo "  # 本地 TCP 密码连接"
echo "  psql -U postgres -h 127.0.0.1 -p ${PG_PORT}"
echo "  # 输入密码: ${PG_ROOT_PASSWORD}"
echo ""
echo "  # 远程连接（从其他机器）"
echo "  psql -U postgres -h $(hostname -I 2>/dev/null | awk '{print $1}' || echo '<服务器IP>') -p ${PG_PORT}"
echo ""
echo "  # 环境变量方式"
echo "  PGPASSWORD='${PG_ROOT_PASSWORD}' psql -U postgres -h <服务器IP> -p ${PG_PORT}"
if ${FOR_GITLAB}; then
    echo ""
    echo "  # GitLab 数据库连接"
    echo "  PGPASSWORD='${PG_ROOT_PASSWORD}' psql -U git -h <服务器IP> -p ${PG_PORT} -d gitlabhq_production"
fi
echo ""
echo "  ── 管理命令 ──"
echo "  systemctl status ${SERVICE_NAME}"
echo "  systemctl {start|stop|restart|reload} ${SERVICE_NAME}"
echo ""
echo "  ── 目录 ──"
echo "  安装: ${INSTALL_DIR}"
echo "  数据: ${DATA_DIR}"
echo "  日志: ${LOG_DIR}"
echo ""
echo "  卸载: bash uninstall_postgresql.sh"
echo "============================================"
