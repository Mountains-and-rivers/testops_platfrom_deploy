#!/bin/bash
# ============================================================
# Loki 3.x — 裸机单机部署（CentOS 9）
#
# 安装方式: 官方预编译二进制（源码编译 TODO）
# 本地优先: 脚本同目录 loki-linux-amd64.zip
#
# 用法: bash install_loki.sh [--port 3100]
# ═══════════════════════════════════════════════
# TODO: 源码编译模式（预留）
#   - [ ] git clone https://github.com/grafana/loki.git → make loki
# ═══════════════════════════════════════════════
set -euo pipefail; cd /tmp

LOKI_VERSION="${LOKI_VERSION:-3.4.0}"
LOKI_ZIP="loki-linux-amd64.zip"
LOKI_URL="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/${LOKI_ZIP}"
LOKI_HOME="${LOKI_HOME:-/opt/loki}"
LOKI_USER="${LOKI_USER:-loki}"
LOKI_PORT="${LOKI_PORT:-3100}"
LOG_DIR="${LOG_DIR:-/var/log/loki}"
DATA_DIR="${DATA_DIR:-/data/loki}"

while [[ $# -gt 0 ]]; do case "$1" in --port) LOKI_PORT="$2"; shift 2;; --source) echo "源码编译 TODO"; exit 0;; *) shift;; esac; done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Loki ${LOKI_VERSION} 单机部署（轻量日志聚合）"
echo "  端口: ${LOKI_PORT}"
echo "============================================"

step "[0/5] 检查..."
[ -x "${LOKI_HOME}/loki-linux-amd64" ] && { ver=$(${LOKI_HOME}/loki-linux-amd64 --version 2>&1 | head -1); info "  已安装: ${ver}"; exit 0; }
systemctl stop loki 2>/dev/null || true

step "[1/5] 获取..."
if _PKG=$(get_local "${LOKI_ZIP}"); then info "  使用本地: $(basename ${_PKG})"; cp "${_PKG}" "/tmp/${LOKI_ZIP}"
else info "  下载: ${LOKI_URL}"; wget -q --show-progress -O "/tmp/${LOKI_ZIP}" "${LOKI_URL}" 2>/dev/null || curl -L -o "/tmp/${LOKI_ZIP}" "${LOKI_URL}" || err "下载失败"
     mkdir -p /tmp/build-cache && cp "/tmp/${LOKI_ZIP}" "/tmp/build-cache/${LOKI_ZIP}" 2>/dev/null || true; fi
rm -rf "${LOKI_HOME}"; mkdir -p "${LOKI_HOME}"
unzip -o "/tmp/${LOKI_ZIP}" -d "${LOKI_HOME}" 2>&1 | tail -1 || err "解压失败"
chmod +x "${LOKI_HOME}/loki-linux-amd64"; rm -f "/tmp/${LOKI_ZIP}"
info "  ✓ Loki v${LOKI_VERSION}"

step "[2/5] 配置..."
id ${LOKI_USER} &>/dev/null || { groupadd ${LOKI_USER} 2>/dev/null || true; useradd -r -g ${LOKI_USER} -s /bin/false ${LOKI_USER} 2>/dev/null || true; }
mkdir -p "${LOG_DIR}" "${DATA_DIR}/loki"; chown -R ${LOKI_USER}:${LOKI_USER} "${LOKI_HOME}" "${LOG_DIR}" "${DATA_DIR}"

cat > "${LOKI_HOME}/config.yaml" << EOF
auth_enabled: false
server:
  http_listen_port: ${LOKI_PORT}
  grpc_listen_port: 0
common:
  path_prefix: ${DATA_DIR}/loki
  storage:
    filesystem:
      chunks_directory: ${DATA_DIR}/loki/chunks
      rules_directory: ${DATA_DIR}/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  allow_structured_metadata: true
EOF
chown ${LOKI_USER}:${LOKI_USER} "${LOKI_HOME}/config.yaml"
info "  ✓ config.yaml → ${LOKI_HOME}/config.yaml"

step "[3/5] systemd..."
cat > /etc/systemd/system/loki.service << EOF
[Unit]
Description=Loki ${LOKI_VERSION} - Log Aggregation
After=network.target
[Service]
Type=simple; User=${LOKI_USER}; Group=${LOKI_USER}
ExecStart=${LOKI_HOME}/loki-linux-amd64 -config.file=${LOKI_HOME}/config.yaml
Restart=on-failure; RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable loki; systemctl start loki; sleep 3
systemctl is-active loki &>/dev/null || { warn "  启动失败: journalctl -u loki -n 30"; err "Loki 启动失败"; }
info "  ✓ loki 已启动 + 开机自启"

step "[4/5] 验证..."
PASS=0; pgrep -f loki &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗"
ss -tlnp 2>/dev/null | grep -q ":${LOKI_PORT}" && { info "  ✓ 端口 ${LOKI_PORT} 已监听"; PASS=$((PASS+1)); } || warn "  ✗"
firewall-cmd --add-port=${LOKI_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
step "[5/5] 完成 (${PASS}/2)"
echo "============================================"
echo "  Loki ${LOKI_VERSION} 安装完成"
echo "  端口: ${LOKI_PORT}"
echo "  下一步: bash install_promtail.sh → 采集日志到 Loki"
echo "============================================"
