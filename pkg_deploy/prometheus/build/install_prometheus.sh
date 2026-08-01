#!/bin/bash
# ============================================================
# Prometheus 3.x — 裸机单机部署（CentOS 9）
#
# 安装方式: 官方预编译二进制 tar.gz（源码编译 TODO）
# 本地优先: 脚本同目录 prometheus-*.tar.gz
#
# 用法: bash install_prometheus.sh [--port 9090]
# ═══════════════════════════════════════════════
# TODO: 源码编译模式（预留）
#   - [ ] git clone https://github.com/prometheus/prometheus.git → make build
# ═══════════════════════════════════════════════
set -euo pipefail; cd /tmp

PROM_VERSION="${PROM_VERSION:-3.4.0}"
PROM_TAR="prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
PROM_URL="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${PROM_TAR}"
PROM_HOME="${PROM_HOME:-/opt/prometheus}"
PROM_USER="${PROM_USER:-prometheus}"
PROM_PORT="${PROM_PORT:-9090}"
DATA_DIR="${DATA_DIR:-/data/prometheus}"
LOG_DIR="${LOG_DIR:-/var/log/prometheus}"
RETENTION="${RETENTION:-30d}"

while [[ $# -gt 0 ]]; do case "$1" in --port) PROM_PORT="$2"; shift 2;; --source) echo "源码编译 TODO"; exit 0;; *) shift;; esac; done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Prometheus ${PROM_VERSION} 单机部署"
echo "  端口: ${PROM_PORT}  |  保留: ${RETENTION}"
echo "============================================"

step "[0/5] 检查..."
[ -x "${PROM_HOME}/prometheus" ] && { ver=$(${PROM_HOME}/prometheus --version 2>&1 | head -1); info "  已安装: ${ver}"; exit 0; }
systemctl stop prometheus 2>/dev/null || true

step "[1/5] 获取..."
if _PKG=$(get_local "${PROM_TAR}"); then info "  使用本地: $(basename ${_PKG})"; cp "${_PKG}" "/tmp/${PROM_TAR}"
else info "  下载: ${PROM_URL}"; wget -q --show-progress -O "/tmp/${PROM_TAR}" "${PROM_URL}" 2>/dev/null || curl -L -o "/tmp/${PROM_TAR}" "${PROM_URL}" || err "下载失败"
     mkdir -p /tmp/build-cache && cp "/tmp/${PROM_TAR}" "/tmp/build-cache/${PROM_TAR}" 2>/dev/null || true; fi
rm -rf "${PROM_HOME}"; tar -xzf "/tmp/${PROM_TAR}" -C /opt; mv /opt/prometheus-* "${PROM_HOME}"; rm -f "/tmp/${PROM_TAR}"
info "  ✓ $(${PROM_HOME}/prometheus --version 2>&1 | head -1)"

step "[2/5] 配置..."
id ${PROM_USER} &>/dev/null || { groupadd ${PROM_USER} 2>/dev/null || true; useradd -r -g ${PROM_USER} -s /bin/false ${PROM_USER} 2>/dev/null || true; }
mkdir -p "${DATA_DIR}" "${LOG_DIR}"; chown -R ${PROM_USER}:${PROM_USER} "${PROM_HOME}" "${DATA_DIR}" "${LOG_DIR}"

if [ -f "${SCRIPT_DIR}/prometheus.yml" ]; then
    cp "${SCRIPT_DIR}/prometheus.yml" "${PROM_HOME}/prometheus.yml"
    sed -i "s|{{PROM_PORT}}|${PROM_PORT}|g; s|{{DATA_DIR}}|${DATA_DIR}|g" "${PROM_HOME}/prometheus.yml"
else
    cat > "${PROM_HOME}/prometheus.yml" << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: []

rule_files: []

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:${PROM_PORT}']

  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
EOF
fi

# systemd
step "[3/5] systemd..."
cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus ${PROM_VERSION} - Monitoring System
After=network.target
[Service]
Type=simple; User=${PROM_USER}; Group=${PROM_USER}
ExecStart=${PROM_HOME}/prometheus --config.file=${PROM_HOME}/prometheus.yml \\
    --storage.tsdb.path=${DATA_DIR} --storage.tsdb.retention.time=${RETENTION} \\
    --web.listen-address=:${PROM_PORT}
Restart=on-failure; RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable prometheus; systemctl start prometheus; sleep 3
systemctl is-active prometheus &>/dev/null || { warn "  启动失败: journalctl -u prometheus -n 30"; err "Prometheus 启动失败"; }
info "  ✓ prometheus 已启动 + 开机自启"

step "[4/5] 验证..."
PASS=0; pgrep -f prometheus &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗"
ss -tlnp 2>/dev/null | grep -q ":${PROM_PORT}" && { info "  ✓ 端口 ${PROM_PORT} 已监听"; PASS=$((PASS+1)); } || warn "  ✗"
firewall-cmd --add-port=${PROM_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
step "[5/5] 完成 (${PASS}/2)"
echo "============================================"
echo "  Prometheus ${PROM_VERSION} 安装完成"
echo "  访问: http://<IP>:${PROM_PORT}"
echo "============================================"
