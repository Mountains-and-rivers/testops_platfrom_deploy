#!/bin/bash
# ============================================================
# MeterSphere v3.x — 裸机 systemd 进程安装
# 前置: bash build_metersphere.sh（产出 /opt/metersphere）
# 用法: bash install_metersphere.sh [--port 8081] [--db-host 127.0.0.1]
# ============================================================
set -euo pipefail

# 必须在 cd 之前计算脚本目录，否则相对路径 $0 会解析到 /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
cd /tmp

# ── 配置 ──
MS_DIR="${MS_DIR:-/opt/metersphere}"
MS_PORT="${MS_PORT:-8081}"
MS_USER="${MS_USER:-metersphere}"
LOG_DIR="${LOG_DIR:-/var/log/metersphere}"
DATA_DIR="${DATA_DIR:-/data/metersphere}"
JDK_DIR="${JDK_DIR:-/opt/jdk17}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-metersphere}"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-Password123!@#}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASS="${REDIS_PASS:-Pg1@zendao2024}"
KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-127.0.0.1:9092}"
HEAP_MIN="${HEAP_MIN:-2048m}"
HEAP_MAX="${HEAP_MAX:-4096m}"
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)        MS_PORT="$2"; shift 2 ;;
        --db-host)     DB_HOST="$2"; shift 2 ;;
        --db-port)     DB_PORT="$2"; shift 2 ;;
        --db-name)     DB_NAME="$2"; shift 2 ;;
        --db-user)     DB_USER="$2"; shift 2 ;;
        --db-pass)     DB_PASS="$2"; shift 2 ;;
        --redis-host)  REDIS_HOST="$2"; shift 2 ;;
        --kafka)       KAFKA_BOOTSTRAP="$2"; shift 2 ;;
        --force)       FORCE=true; shift ;;
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

[ "$(id -u)" -eq 0 ] || err "需要 root 权限"

echo "============================================"
echo "  MeterSphere 裸机安装"
echo "  端口: ${MS_PORT}  |  DB: ${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "============================================"

# ═══ 0. 检查 ═══
step "[0/5] 检查..."

if ! ${FORCE} && systemctl is-active metersphere &>/dev/null; then
    info "  metersphere 已运行，跳过安装（--force 强制重装）"; exit 0
fi

systemctl stop metersphere 2>/dev/null || true

# 查找 JAR
MS_JAR=$(find "${MS_DIR}" -name "metersphere*.jar" -not -name "*sources*" -not -name "*javadoc*" | head -1)
[ -n "${MS_JAR}" ] && [ -f "${MS_JAR}" ] || err "未找到 JAR，请先执行 build_metersphere.sh"

# JDK 检查
_JAVA="${JDK_DIR}/bin/java"
[ -x "${_JAVA}" ] || _JAVA=$(which java 2>/dev/null || echo "")
[ -n "${_JAVA}" ] && [ -x "${_JAVA}" ] || err "JDK 未找到: ${JDK_DIR}"
info "  ✓ $(${_JAVA} --version 2>&1 | head -1)"
info "  ✓ JAR: ${MS_JAR}"

# ═══ 1. 配置 ═══
step "[1/5] 配置 MeterSphere..."

# 创建用户
id ${MS_USER} &>/dev/null || { groupadd ${MS_USER} 2>/dev/null || true; useradd -r -g ${MS_USER} -s /bin/false ${MS_USER} 2>/dev/null || true; }

# 目录
mkdir -p "${LOG_DIR}" "${DATA_DIR}/uploads" "${DATA_DIR}/tmp"
chown -R ${MS_USER}:${MS_USER} "${LOG_DIR}" "${DATA_DIR}"

# 生成 application 配置
mkdir -p "${MS_DIR}/config"
cat > "${MS_DIR}/config/application.properties" << PROPEOF
server.port=${MS_PORT}
spring.datasource.url=jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}?useSSL=false&serverTimezone=UTC&characterEncoding=utf8
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASS}
spring.redis.host=${REDIS_HOST}
spring.redis.port=${REDIS_PORT}
spring.redis.password=${REDIS_PASS}
spring.kafka.bootstrap-servers=${KAFKA_BOOTSTRAP}
logging.file.path=${LOG_DIR}
metersphere.file.upload.dir=${DATA_DIR}/uploads
PROPEOF
chown ${MS_USER}:${MS_USER} "${MS_DIR}/config/application.properties"
info "  ✓ application.properties → ${MS_DIR}/config/"

# ═══ 2. systemd ═══
step "[2/5] 配置 systemd..."

cat > /etc/systemd/system/metersphere.service << SYSTEMDEOF
[Unit]
Description=MeterSphere - Open Source Testing Platform
After=network.target

[Service]
Type=simple
User=${MS_USER}
Group=${MS_USER}
WorkingDirectory=${MS_DIR}
ExecStart=${_JAVA} -Xms${HEAP_MIN} -Xmx${HEAP_MAX} \\
    -jar ${MS_JAR} \\
    --spring.config.additional-location=${MS_DIR}/config/
Restart=on-failure
RestartSec=15
StandardOutput=append:${LOG_DIR}/ms.log
StandardError=append:${LOG_DIR}/ms-error.log

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable metersphere
systemctl start metersphere
sleep 5
systemctl is-active metersphere &>/dev/null || {
    warn "  启动失败，查看: journalctl -u metersphere -n 30"
    err "MeterSphere 启动失败"
}
info "  ✓ metersphere 已启动 + 开机自启"

# ═══ 3. 等待就绪 ═══
step "[3/5] 等待 MeterSphere 就绪..."

READY=false
for i in $(seq 1 60); do
    STATUS=$(curl -sk --connect-timeout 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MS_PORT}" 2>/dev/null || echo "000")
    if [ "${STATUS}" != "000" ] && [ "${STATUS}" != "502" ] && [ "${STATUS}" != "503" ]; then
        info "  MeterSphere 就绪 (${i}/60) — HTTP ${STATUS}"
        READY=true; break
    fi
    [ $i -eq 60 ] && warn "  超时，检查: journalctl -u metersphere -n 50" || sleep 5
done

# ═══ 4. 验证 ═══
step "[4/5] 验证..."

PASS=0
pgrep -f "metersphere.*jar" &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗ 进程未运行"

if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${MS_PORT}" && { info "  ✓ 端口 ${MS_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${MS_PORT} 未监听"
fi

firewall-cmd --add-port=${MS_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

# ═══ 5. 完成 ═══
step "[5/5] 完成 ($(echo ${PASS}/2 项通过))"

echo ""
echo "--- 服务状态 ---"
systemctl status metersphere --no-pager -l 2>/dev/null | head -5 || true
echo ""

echo "============================================"
echo "  MeterSphere 安装完成"
echo ""
echo "  访问:     http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<IP>'):${MS_PORT}"
echo "  配置:     ${MS_DIR}/config/application.properties"
echo "  日志:     ${LOG_DIR}/"
echo "  数据:     ${DATA_DIR}/"
echo ""
echo "  管理:     systemctl {start|stop|restart|status} metersphere"
echo "  卸载:     bash clean_metersphere.sh"
echo "============================================"
