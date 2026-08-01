#!/bin/bash
# ============================================================
# Logstash 8.17 — 裸机单机部署（CentOS 9）
# 用法: bash install_logstash.sh [--es-host 127.0.0.1:9200]
# 源码编译: TODO（预留）
# ============================================================
set -euo pipefail

# 必须在 cd 之前计算脚本目录，否则相对路径 $0 会解析到 /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
cd /tmp

LS_VERSION="${LS_VERSION:-8.17.0}"
LS_TAR="logstash-${LS_VERSION}-linux-x86_64.tar.gz"
LS_URL="https://artifacts.elastic.co/downloads/logstash/${LS_TAR}"
LS_HOME="${LS_HOME:-/opt/logstash}"
LS_USER="${LS_USER:-logstash}"
ES_HOST="${ES_HOST:-127.0.0.1:9200}"
LS_PORT="${LS_PORT:-5044}"
LS_API_PORT="${LS_API_PORT:-9600}"
LOG_DIR="${LOG_DIR:-/var/log/logstash}"
DATA_DIR="${DATA_DIR:-/data/logstash}"

while [[ $# -gt 0 ]]; do case "$1" in --es-host) ES_HOST="$2"; shift 2;; --source) echo "源码编译 TODO"; exit 0;; *) shift;; esac; done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Logstash ${LS_VERSION} 单机部署"
echo "  端口: ${LS_PORT}  |  ES: ${ES_HOST}"
echo "============================================"

step "[0/5] 检查..."
[ -x "${LS_HOME}/bin/logstash" ] && { info "  已安装: $(${LS_HOME}/bin/logstash --version 2>&1)"; systemctl is-active logstash &>/dev/null || systemctl start logstash 2>/dev/null || true; info "  跳过安装"; exit 0; }
systemctl stop logstash 2>/dev/null || true

step "[1/5] 获取..."
if _PKG=$(get_local "${LS_TAR}"); then info "  使用本地: $(basename ${_PKG})"; cp "${_PKG}" "/tmp/${LS_TAR}"
else info "  下载: ${LS_URL}"; wget -q --show-progress -O "/tmp/${LS_TAR}" "${LS_URL}" 2>/dev/null || curl -L -o "/tmp/${LS_TAR}" "${LS_URL}" || err "下载失败"
     mkdir -p /tmp/build-cache && cp "/tmp/${LS_TAR}" "/tmp/build-cache/${LS_TAR}" 2>/dev/null || true; fi
rm -rf "${LS_HOME}"; tar -xzf "/tmp/${LS_TAR}" -C /opt; mv /opt/logstash-* "${LS_HOME}"; rm -f "/tmp/${LS_TAR}"
info "  ✓ $(${LS_HOME}/bin/logstash --version 2>&1)"

step "[2/5] 配置..."
id ${LS_USER} &>/dev/null || { groupadd ${LS_USER} 2>/dev/null || true; useradd -r -g ${LS_USER} -s /bin/false ${LS_USER} 2>/dev/null || true; }
mkdir -p "${LOG_DIR}" "${DATA_DIR}"; chown -R ${LS_USER}:${LS_USER} "${LS_HOME}" "${LOG_DIR}" "${DATA_DIR}"

# 默认 pipeline：stdin → elasticsearch
cat > "${LS_HOME}/config/logstash.conf" << EOF
input { beats { port => ${LS_PORT} } }
output { elasticsearch { hosts => ["${ES_HOST}"] } }
EOF
# logstash.yml
cat > "${LS_HOME}/config/logstash.yml" << EOF
http.host: "0.0.0.0"
http.port: ${LS_API_PORT}
path.data: ${DATA_DIR}
path.logs: ${LOG_DIR}
EOF
chown ${LS_USER}:${LS_USER} "${LS_HOME}/config/logstash.conf" "${LS_HOME}/config/logstash.yml"
info "  ✓ logstash.conf → ${LS_HOME}/config/"

step "[3/5] systemd..."
cat > /etc/systemd/system/logstash.service << EOF
[Unit]
Description=Logstash ${LS_VERSION}
After=network.target
[Service]
Type=simple
User=${LS_USER}
Group=${LS_USER}
ExecStart=${LS_HOME}/bin/logstash -f ${LS_HOME}/config/logstash.conf
Restart=on-failure
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable logstash; systemctl start logstash; sleep 5
systemctl is-active logstash &>/dev/null || { warn "  启动失败: journalctl -u logstash -n 30"; err "Logstash 启动失败"; }
info "  ✓ logstash 已启动 + 开机自启"

step "[4/5] 验证..."
PASS=0; pgrep -f logstash &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗ 进程未运行"
ss -tlnp 2>/dev/null | grep -q ":${LS_PORT}" && { info "  ✓ 端口 ${LS_PORT} 已监听"; PASS=$((PASS+1)); } || warn "  ✗"
firewall-cmd --add-port=${LS_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
step "[5/5] 完成 (${PASS}/2)"
echo "============================================"
echo "  Logstash ${LS_VERSION} 安装完成"
echo "  输入: ${LS_PORT}  |  ES: ${ES_HOST}  |  API: ${LS_API_PORT}"
echo "============================================"
