#!/bin/bash
# ============================================================
# MySQL 8.0.35 一键安装（glibc 通用版 tar.xz）
# 包名: mysql-8.0.35-linux-glibc2.28-x86_64.tar.xz
# 下载: https://downloads.mysql.com/archives/get/p/23/file/mysql-8.0.35-linux-glibc2.28-x86_64.tar.xz
# 本地优先: ./ → 脚本同目录 → /tmp/build-cache/ → ~/
# 用法: bash install_mysql.sh
# ============================================================
set -euo pipefail

cd /tmp  # 确保 CWD 有效（防止调用方目录被删导致后续失败）

MYSQL_VERSION="8.0.35"
MYSQL_PKG="mysql-${MYSQL_VERSION}-linux-glibc2.28-x86_64.tar.xz"
MYSQL_DOWNLOAD="https://downloads.mysql.com/archives/get/p/23/file/${MYSQL_PKG}"
MYSQL_ROOT_PASSWORD='Kd9$prL7sQ2!vzB4'
MYSQL_DATABASE="zendao"
MYSQL_PORT="${MYSQL_PORT:-3306}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/mysql}"
DATA_DIR="${DATA_DIR:-/data/mysql}"
LOG_DIR="${LOG_DIR:-/var/log/mysql}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

get_local_pkg() {
    for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do
        [ -f "${d}${MYSQL_PKG}" ] && [ -s "${d}${MYSQL_PKG}" ] && { echo "${d}${MYSQL_PKG}"; return 0; }
    done
    return 1
}

echo "============================================"
echo "  MySQL ${MYSQL_VERSION} 一键安装"
echo "  安装目录: ${INSTALL_DIR}"
echo "  数据目录: ${DATA_DIR}"
echo "============================================"

[ "$(uname -m)" = "x86_64" ] || err "仅支持 x86_64"

# ---- 1. 已安装检测 ----
step "[1/9] 检查已安装..."
if [ -f "${INSTALL_DIR}/bin/mysqld" ]; then
    ver=$(${INSTALL_DIR}/bin/mysqld --version 2>&1 | awk '{print $3}' | cut -d- -f1)
    info "  已安装 MySQL ${ver}"
    [ "${ver}" = "${MYSQL_VERSION}" ] && {
        info "  版本一致，跳过安装"
        systemctl is-active mysqld &>/dev/null || systemctl start mysqld
        info "  安装完成"
        exit 0
    }
    warn "  版本不匹配，覆盖安装"
fi

# ---- 2. 清理冲突 ----
step "[2/9] 清理冲突..."
# 确保彻底停止所有旧 MySQL 进程（含非 systemd 管理的残留进程）
systemctl stop mariadb mysqld 2>/dev/null || true
if pgrep -x mysqld >/dev/null 2>&1; then
    warn "  检测到残留 mysqld 进程，强制终止..."
    pkill -9 mysqld 2>/dev/null || true
    sleep 2
    # 确认已停止
    pgrep -x mysqld >/dev/null 2>&1 && err "mysqld 进程无法停止，请手动检查: ps aux | grep mysqld"
    info "  残留进程已终止"
fi
rpm -e --nodeps mariadb-server mariadb 2>/dev/null || true
rm -f /etc/systemd/system/mysqld.service
systemctl daemon-reload 2>/dev/null || true

# ---- 3. 获取安装包 ----
step "[3/9] 获取安装包..."
cd /tmp
pkg_path=$(get_local_pkg) || true
if [ -n "${pkg_path:-}" ]; then
    info "  使用本地: ${pkg_path}"
    [ "${pkg_path}" != "/tmp/${MYSQL_PKG}" ] && cp "${pkg_path}" "/tmp/${MYSQL_PKG}"
else
    info "  下载: ${MYSQL_DOWNLOAD}"
    wget --show-progress -O "/tmp/${MYSQL_PKG}" "${MYSQL_DOWNLOAD}" \
        || err "下载失败，请手动下载 ${MYSQL_PKG} 放到 ${SCRIPT_DIR}/"
fi
mkdir -p /tmp/build-cache && cp "/tmp/${MYSQL_PKG}" "/tmp/build-cache/${MYSQL_PKG}" 2>/dev/null || true

# ---- 4. 解压安装 ----
step "[4/9] 解压安装（约 1-2 分钟）..."
rm -rf "${INSTALL_DIR}"
tmpdir=$(mktemp -d)
echo "  正在解压 ${MYSQL_PKG}..."
tar -xvf "/tmp/${MYSQL_PKG}" -C "${tmpdir}" 2>&1 | while read line; do echo "    ${line}"; done
mv "${tmpdir}/mysql-${MYSQL_VERSION}-linux-glibc2.28-x86_64" "${INSTALL_DIR}"
rm -rf "${tmpdir}" "/tmp/${MYSQL_PKG}"
info "  已安装: ${INSTALL_DIR}"

# ---- 5. 用户/目录 ----
step "[5/9] 创建用户和目录..."
id mysql &>/dev/null || { groupadd mysql; useradd -r -g mysql -s /bin/false mysql; }
mkdir -p "${DATA_DIR}" "${LOG_DIR}"
chown -R mysql:mysql "${DATA_DIR}" "${LOG_DIR}"

# ---- 6. 配置文件 ----
step "[6/9] 生成配置..."
cat > /etc/my.cnf << MYEOF
[mysqld]
port = ${MYSQL_PORT}
datadir = ${DATA_DIR}
basedir = ${INSTALL_DIR}
socket = /tmp/mysql.sock
pid-file = ${DATA_DIR}/mysqld.pid
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
default-authentication-plugin = mysql_native_password
max_allowed_packet = 64M
max_connections = 500
innodb_buffer_pool_size = 512M
innodb_file_per_table = ON
innodb_flush_log_at_trx_commit = 2
bind-address = 0.0.0.0
log-error = ${LOG_DIR}/error.log
log_error_verbosity = 2
slave_net_timeout = 60
slow_query_log = 1
slow_query_log_file = ${LOG_DIR}/slow.log
long_query_time = 2
binlog_expire_logs_seconds = 604800
max_binlog_size = 512M
# 错误日志轮转：单文件最大 128MB，超过自动切换
log_error_services = log_filter_internal; log_sink_internal
log_error_max_size = 134217728

[client]
socket = /tmp/mysql.sock
default-character-set = utf8mb4
MYEOF
echo "export PATH=${INSTALL_DIR}/bin:\$PATH" > /etc/profile.d/mysql.sh
export PATH="${INSTALL_DIR}/bin:${PATH}"

# ---- 7. 初始化 ----
step "[7/9] 初始化数据库..."
echo "  正在初始化 MySQL 数据目录..."
mysqld --initialize-insecure --user=mysql --basedir="${INSTALL_DIR}" --datadir="${DATA_DIR}" 2>&1 | while read line; do echo "    ${line}"; done
info "  初始化完成: ${DATA_DIR}"

# ---- 8. systemd 服务 ----
step "[8/9] 配置 systemd 服务..."
cat > /etc/systemd/system/mysqld.service << SYSTEMDEOF
[Unit]
Description=MySQL ${MYSQL_VERSION} Database Server
After=network.target

[Service]
Type=forking
User=mysql
Group=mysql
ExecStart=${INSTALL_DIR}/bin/mysqld --daemonize --user=mysql
ExecStop=${INSTALL_DIR}/bin/mysqladmin -u root shutdown
Restart=on-failure
RestartSec=5
PIDFile=${DATA_DIR}/mysqld.pid
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SYSTEMDEOF
systemctl daemon-reload
systemctl enable mysqld
echo "  正在启动 MySQL..."
systemctl start mysqld
for i in $(seq 1 10); do
    if systemctl is-active mysqld &>/dev/null; then break; fi
    echo "  等待 MySQL 启动... (${i}/10)"
    sleep 1
done
if systemctl is-active mysqld &>/dev/null; then
    info "  MySQL 已启动（开机自启已启用）"
else
    warn "  启动失败，查看日志:"
    echo "  --- error.log ---"
    tail -10 "${LOG_DIR}/error.log" 2>/dev/null
    systemctl status mysqld --no-pager -l 2>/dev/null | tail -10
    exit 1
fi

# ---- 9. 安全配置 ----
step "[9/9] 安全配置..."
# <<'SQL' 加引号禁止 bash 展开 $ 符号，密码原样传给 MySQL
mysql -u root --socket=/tmp/mysql.sock << 'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'Kd9$prL7sQ2!vzB4';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'Kd9$prL7sQ2!vzB4';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS `zendao` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
FLUSH PRIVILEGES;
SQL
firewall-cmd --add-port=${MYSQL_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

echo ""
echo "============================================"
echo "  MySQL ${MYSQL_VERSION} 安装完成"
echo "  连接: mysql -u root -p"
echo "  密码: Kd9\$prL7sQ2!vzB4"
echo "  数据库: ${MYSQL_DATABASE}"
echo "  数据目录: ${DATA_DIR}"
echo "  日志目录: ${LOG_DIR}"
echo "  管理: systemctl {start|stop|restart|status} mysqld"
echo "============================================"
