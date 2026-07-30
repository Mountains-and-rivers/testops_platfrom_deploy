#!/bin/bash
# ============================================================
# MySQL 8.0.35 一键卸载（安全模式，不碰系统文件）
# 用法: bash uninstall_mysql.sh
# ============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/local/mysql}"
DATA_DIR="${DATA_DIR:-/data/mysql}"
LOG_DIR="${LOG_DIR:-/var/log/mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_VERSION="8.0.35"
MYSQL_PKG="mysql-${MYSQL_VERSION}-linux-glibc2.28-x86_64.tar.xz"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  MySQL ${MYSQL_VERSION} 一键卸载"
echo "============================================"
echo "  将删除:"
echo "    安装目录: ${INSTALL_DIR}"
echo "    数据目录: ${DATA_DIR}"
echo "    日志目录: ${LOG_DIR}"
echo "    配置文件: /etc/my.cnf"
echo "    服务文件: /etc/systemd/system/mysqld.service"
echo "    环境变量: /etc/profile.d/mysql.sh"
echo "    用户/组:   mysql"
echo ""
read -p "  确认删除? (yes/no): " c
[ "${c}" != "yes" ] && { info "已取消"; exit 0; }

# 1. 停止
step "[1/6] 停止服务..."
systemctl stop mysqld 2>/dev/null || true
systemctl disable mysqld 2>/dev/null || true
# 确保停止所有残留 mysqld 进程（含手动启动、非 systemd 管理的）
if pgrep -x mysqld >/dev/null 2>&1; then
    info "  存在残留 mysqld 进程，强制终止..."
    pkill -9 mysqld 2>/dev/null || true
    sleep 2
fi

# 2. 删除安装目录（安全校验：非系统路径）
step "[2/6] 删除安装目录..."
[ "${INSTALL_DIR}" != "/" ] && [ "${INSTALL_DIR}" != "/usr" ] && [ "${INSTALL_DIR}" != "/usr/local" ] \
    && rm -rf "${INSTALL_DIR}" && info "  ${INSTALL_DIR} ✓"

# 3. 删除数据和日志
step "[3/6] 删除数据/日志..."
rm -rf "${DATA_DIR}" && info "  ${DATA_DIR} ✓"
rm -rf "${LOG_DIR}" && info "  ${LOG_DIR} ✓"

# 4. 删除配置和残留
step "[4/6] 删除配置..."
rm -f /etc/my.cnf /etc/profile.d/mysql.sh /tmp/mysql.sock /var/run/mysqld.pid
rm -f /etc/systemd/system/mysqld.service /usr/lib/systemd/system/mysqld.service
rm -f /tmp/"${MYSQL_PKG}" /tmp/build-cache/"${MYSQL_PKG}"
info "  配置文件 ✓"

# 5. 删除用户
step "[5/6] 删除用户..."
userdel mysql 2>/dev/null && info "  用户 mysql ✓" || info "  用户 mysql 不存在"
groupdel mysql 2>/dev/null && info "  组 mysql ✓" || info "  组 mysql 不存在"

# 6. 防火墙 + systemd
step "[6/6] 清理防火墙..."
firewall-cmd --remove-port=${MYSQL_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null && info "  端口 ${MYSQL_PORT} ✓" || info "  端口 ${MYSQL_PORT} 无规则"
systemctl daemon-reload

echo ""
echo "============================================"
echo "  MySQL 卸载完成（系统文件未动）"
echo "============================================"
