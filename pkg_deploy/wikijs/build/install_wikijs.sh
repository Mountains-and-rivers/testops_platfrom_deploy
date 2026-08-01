#!/bin/bash
# ============================================================
# Wiki.js 2.x — 裸机 systemd 进程安装
# 前置: bash build_wikijs.sh（产出 /opt/wiki）
# 用法: bash install_wikijs.sh [--port 3000] [--db-host 127.0.0.1]
# ============================================================
set -euo pipefail
cd /tmp

# ── 配置 ──
WIKI_DIR="${WIKI_DIR:-/opt/wiki}"
WIKI_PORT="${WIKI_PORT:-3000}"
WIKI_USER="${WIKI_USER:-wiki}"
LOG_DIR="${LOG_DIR:-/var/log/wiki}"
DATA_DIR="${DATA_DIR:-/data/wiki}"
DB_TYPE="${DB_TYPE:-postgres}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-wiki}"
DB_USER="${DB_USER:-postgres}"
DB_PASS="${DB_PASS:-Pg1@zendao2024}"
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    WIKI_PORT="$2"; shift 2 ;;
        --db-host) DB_HOST="$2"; shift 2 ;;
        --db-port) DB_PORT="$2"; shift 2 ;;
        --db-name) DB_NAME="$2"; shift 2 ;;
        --db-user) DB_USER="$2"; shift 2 ;;
        --db-pass) DB_PASS="$2"; shift 2 ;;
        --force)   FORCE=true; shift ;;
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

[ "$(id -u)" -eq 0 ] || err "需要 root 权限"

echo "============================================"
echo "  Wiki.js 裸机安装"
echo "  端口: ${WIKI_PORT}  |  DB: ${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "============================================"

# ═══ 0. 检查 ═══
step "[0/5] 检查..."

[ -f "${WIKI_DIR}/package.json" ] || err "Wiki.js 未构建: ${WIKI_DIR}/package.json 不存在，请先执行 build_wikijs.sh"

if ! ${FORCE} && systemctl is-active wiki &>/dev/null; then
    info "  wiki 服务已运行，跳过安装（--force 强制重装）"; exit 0
fi

systemctl stop wiki 2>/dev/null || true

# Node 可用性
export PATH="/usr/local/node/bin:/usr/local/bin:${PATH}"
command -v node &>/dev/null || err "Node.js 未安装，请先执行 build_wikijs.sh"
info "  ✓ Node.js $(node --version)"

# ═══ 1. 配置 ═══
step "[1/5] 配置 Wiki.js..."

# 创建 wiki 用户
id ${WIKI_USER} &>/dev/null || { groupadd ${WIKI_USER} 2>/dev/null || true; useradd -r -g ${WIKI_USER} -s /bin/false ${WIKI_USER} 2>/dev/null || true; }

# 目录
mkdir -p "${LOG_DIR}" "${DATA_DIR}/uploads" "${DATA_DIR}/cache"
chown -R ${WIKI_USER}:${WIKI_USER} "${WIKI_DIR}" "${LOG_DIR}" "${DATA_DIR}"

# 生成 config.yml（从脚本同目录模板优先）
if [ -f "${SCRIPT_DIR}/config.yml" ]; then
    info "  使用本地模板: ${SCRIPT_DIR}/config.yml"
    cp "${SCRIPT_DIR}/config.yml" "${WIKI_DIR}/config.yml"
    sed -i "s|{{WIKI_PORT}}|${WIKI_PORT}|g"          "${WIKI_DIR}/config.yml"
    sed -i "s|{{DB_HOST}}|${DB_HOST}|g"              "${WIKI_DIR}/config.yml"
    sed -i "s|{{DB_PORT}}|${DB_PORT}|g"              "${WIKI_DIR}/config.yml"
    sed -i "s|{{DB_NAME}}|${DB_NAME}|g"              "${WIKI_DIR}/config.yml"
    sed -i "s|{{DB_USER}}|${DB_USER}|g"              "${WIKI_DIR}/config.yml"
    sed -i "s|{{DB_PASS}}|${DB_PASS}|g"              "${WIKI_DIR}/config.yml"
    sed -i "s|{{DATA_DIR}}|${DATA_DIR}|g"            "${WIKI_DIR}/config.yml"
    sed -i "s|{{LOG_DIR}}|${LOG_DIR}|g"              "${WIKI_DIR}/config.yml"
else
    info "  生成默认 config.yml..."
    cat > "${WIKI_DIR}/config.yml" << YMLCONF
port: ${WIKI_PORT}
bindIP: 0.0.0.0
db:
  type: ${DB_TYPE}
  host: ${DB_HOST}
  port: ${DB_PORT}
  db: ${DB_NAME}
  user: ${DB_USER}
  pass: ${DB_PASS}
  ssl: false
logLevel: info
dataPath: ${DATA_DIR}
uploads:
  maxFileSize: 100
YMLCONF
fi
chown ${WIKI_USER}:${WIKI_USER} "${WIKI_DIR}/config.yml"
info "  ✓ config.yml → ${WIKI_DIR}/config.yml"

# ═══ 2. systemd 服务 ═══
step "[2/5] 配置 systemd..."

cat > /etc/systemd/system/wiki.service << SYSTEMDEOF
[Unit]
Description=Wiki.js - Modern Wiki Platform
After=network.target

[Service]
Type=simple
User=${WIKI_USER}
Group=${WIKI_USER}
WorkingDirectory=${WIKI_DIR}
ExecStart=/usr/local/node/bin/node ${WIKI_DIR}/server
Restart=on-failure
RestartSec=10
Environment=NODE_ENV=production
StandardOutput=append:${LOG_DIR}/wiki.log
StandardError=append:${LOG_DIR}/wiki-error.log

[Install]
WantedBy=multi-user.target
SYSTEMDEOF

systemctl daemon-reload
systemctl enable wiki
systemctl start wiki
sleep 3
systemctl is-active wiki &>/dev/null || {
    warn "  启动失败，查看: journalctl -u wiki -n 30"
    err "Wiki.js 启动失败"
}
info "  ✓ wiki 已启动 + 开机自启"

# ═══ 3. 等待就绪 ═══
step "[3/5] 等待 Wiki.js 就绪..."

READY=false
for i in $(seq 1 30); do
    STATUS=$(curl -sk --connect-timeout 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WIKI_PORT}" 2>/dev/null || echo "000")
    if [ "${STATUS}" = "200" ] || [ "${STATUS}" = "302" ] || [ "${STATUS}" = "301" ]; then
        info "  Wiki.js 就绪 (${i}/30) — HTTP ${STATUS}"
        READY=true; break
    fi
    [ $i -eq 30 ] && warn "  超时 (30x3s)，检查: tail -50 ${LOG_DIR}/wiki.log" || sleep 3
done

# ═══ 4. 验证 ═══
step "[4/5] 验证..."

PASS=0
pgrep -f "node.*server" &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗ 进程未运行"

if command -v ss &>/dev/null; then
    ss -tlnp | grep -q ":${WIKI_PORT}" && { info "  ✓ 端口 ${WIKI_PORT} 已监听"; PASS=$((PASS+1)); } \
        || warn "  ✗ 端口 ${WIKI_PORT} 未监听"
fi

firewall-cmd --add-port=${WIKI_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

# ═══ 5. 完成 ═══
step "[5/5] 完成 ($(echo ${PASS}/2 项通过))"

echo ""
echo "--- 服务状态 ---"
systemctl status wiki --no-pager -l 2>/dev/null | head -5 || true
echo ""

echo "============================================"
echo "  Wiki.js 安装完成"
echo ""
echo "  访问:     http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<IP>'):${WIKI_PORT}"
echo "  配置:     ${WIKI_DIR}/config.yml"
echo "  日志:     ${LOG_DIR}/"
echo "  数据:     ${DATA_DIR}/"
echo ""
echo "  管理:     systemctl {start|stop|restart|status} wiki"
echo "  卸载:     bash clean_wikijs.sh"
echo "============================================"
