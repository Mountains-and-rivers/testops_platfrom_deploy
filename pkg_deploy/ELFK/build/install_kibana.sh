#!/bin/bash
# ============================================================
# Kibana 8.17 — 裸机单机部署（CentOS 9）
# 用法: bash install_kibana.sh [--port 5601] [--es-host 127.0.0.1:9200]
# 源码编译: TODO（预留）
# ============================================================
set -euo pipefail

# 必须在 cd 之前计算脚本目录，否则相对路径 $0 会解析到 /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
cd /tmp

KB_VERSION="${KB_VERSION:-8.17.0}"
KB_TAR="kibana-${KB_VERSION}-linux-x86_64.tar.gz"
KB_URL="https://artifacts.elastic.co/downloads/kibana/${KB_TAR}"
KB_HOME="${KB_HOME:-/opt/kibana}"
KB_USER="${KB_USER:-kibana}"
ES_HOST="${ES_HOST:-127.0.0.1:9200}"
KB_PORT="${KB_PORT:-5601}"
LOG_DIR="${LOG_DIR:-/var/log/kibana}"
DATA_DIR="${DATA_DIR:-/data/kibana}"

while [[ $# -gt 0 ]]; do case "$1" in --port) KB_PORT="$2"; shift 2;; --es-host) ES_HOST="$2"; shift 2;; --source) echo "源码编译 TODO"; exit 0;; *) shift;; esac; done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Kibana ${KB_VERSION} 单机部署"
echo "  端口: ${KB_PORT}  |  ES: ${ES_HOST}"
echo "============================================"

step "[0/5] 检查..."
[ -x "${KB_HOME}/bin/kibana" ] && { info "  已安装: $(${KB_HOME}/bin/kibana --version 2>&1)"; systemctl is-active kibana &>/dev/null || systemctl start kibana 2>/dev/null || true; info "  跳过安装"; exit 0; }
systemctl stop kibana 2>/dev/null || true

step "[1/5] 获取..."
if _PKG=$(get_local "${KB_TAR}"); then info "  使用本地: $(basename ${_PKG})"; cp "${_PKG}" "/tmp/${KB_TAR}"
else info "  下载: ${KB_URL}"; wget -q --show-progress -O "/tmp/${KB_TAR}" "${KB_URL}" 2>/dev/null || curl -L -o "/tmp/${KB_TAR}" "${KB_URL}" || err "下载失败"
     mkdir -p /tmp/build-cache && cp "/tmp/${KB_TAR}" "/tmp/build-cache/${KB_TAR}" 2>/dev/null || true; fi
rm -rf "${KB_HOME}"; tar -xzf "/tmp/${KB_TAR}" -C /opt; mv /opt/kibana-* "${KB_HOME}"; rm -f "/tmp/${KB_TAR}"
info "  ✓ $(${KB_HOME}/bin/kibana --version 2>&1)"

step "[2/5] 配置..."
id ${KB_USER} &>/dev/null || { groupadd ${KB_USER} 2>/dev/null || true; useradd -r -g ${KB_USER} -s /bin/false ${KB_USER} 2>/dev/null || true; }
mkdir -p "${LOG_DIR}" "${DATA_DIR}"; chown -R ${KB_USER}:${KB_USER} "${KB_HOME}" "${LOG_DIR}" "${DATA_DIR}"
if [ -f "${SCRIPT_DIR}/kibana.yml" ]; then
    cp "${SCRIPT_DIR}/kibana.yml" "${KB_HOME}/config/kibana.yml"
    sed -i "s|{{KB_PORT}}|${KB_PORT}|g; s|{{ES_HOST}}|${ES_HOST}|g" "${KB_HOME}/config/kibana.yml"
else
    cat > "${KB_HOME}/config/kibana.yml" << EOF
server.port: ${KB_PORT}
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://${ES_HOST}"]
logging.root.level: info
path.data: ${DATA_DIR}
EOF
fi
info "  ✓ kibana.yml → ${KB_HOME}/config/"

step "[3/5] systemd..."
cat > /etc/systemd/system/kibana.service << EOF
[Unit]
Description=Kibana ${KB_VERSION}
After=network.target elasticsearch.service
[Service]
Type=simple
User=${KB_USER}; Group=${KB_USER}
ExecStart=${KB_HOME}/bin/kibana
Restart=on-failure
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable kibana; systemctl start kibana; sleep 5
systemctl is-active kibana &>/dev/null || { warn "  启动失败: journalctl -u kibana -n 30"; err "Kibana 启动失败"; }
info "  ✓ kibana 已启动 + 开机自启"

step "[4/5] 验证..."
PASS=0; pgrep -f kibana &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗"
ss -tlnp 2>/dev/null | grep -q ":${KB_PORT}" && { info "  ✓ 端口 ${KB_PORT} 已监听"; PASS=$((PASS+1)); } || warn "  ✗"
firewall-cmd --add-port=${KB_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
step "[5/5] 完成 (${PASS}/2)"
echo "============================================"
echo "  Kibana ${KB_VERSION} 安装完成"
echo "  访问: http://<IP>:${KB_PORT}"
echo "============================================"
