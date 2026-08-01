#!/bin/bash
# ============================================================
# Node Exporter 1.x — 裸机部署（CentOS 9）
#
# 安装方式: 官方预编译二进制 tar.gz（源码编译 TODO）
# 本地优先: 脚本同目录 node_exporter-*.tar.gz
#
# 用法: bash install_node_exporter.sh [--port 9100]
# ============================================================
# TODO: 源码编译模式（预留）
# ═══════════════════════════════════════════════
set -euo pipefail

# 必须在 cd 之前计算脚本目录，否则相对路径 $0 会解析到 /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
cd /tmp

NE_VERSION="${NE_VERSION:-1.9.0}"
NE_TAR="node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
NE_URL="https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/${NE_TAR}"
NE_HOME="${NE_HOME:-/opt/node_exporter}"
NE_USER="${NE_USER:-node_exporter}"
NE_PORT="${NE_PORT:-9100}"

while [[ $# -gt 0 ]]; do case "$1" in --port) NE_PORT="$2"; shift 2;; --source) echo "源码编译 TODO"; exit 0;; *) shift;; esac; done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Node Exporter ${NE_VERSION} 部署"
echo "  端口: ${NE_PORT}"
echo "============================================"

step "[0/4] 检查..."
[ -x "${NE_HOME}/node_exporter" ] && { ver=$(${NE_HOME}/node_exporter --version 2>&1 | head -1); info "  已安装: ${ver}"; exit 0; }
systemctl stop node_exporter 2>/dev/null || true

step "[1/4] 获取..."
if _PKG=$(get_local "${NE_TAR}"); then info "  使用本地: $(basename ${_PKG})"; cp "${_PKG}" "/tmp/${NE_TAR}"
else info "  下载: ${NE_URL}"; wget -q --show-progress -O "/tmp/${NE_TAR}" "${NE_URL}" 2>/dev/null || curl -L -o "/tmp/${NE_TAR}" "${NE_URL}" || err "下载失败"
     mkdir -p /tmp/build-cache && cp "/tmp/${NE_TAR}" "/tmp/build-cache/${NE_TAR}" 2>/dev/null || true; fi
rm -rf "${NE_HOME}"; tar -xzf "/tmp/${NE_TAR}" -C /opt; mv /opt/node_exporter-* "${NE_HOME}"; rm -f "/tmp/${NE_TAR}"
info "  ✓ $(${NE_HOME}/node_exporter --version 2>&1 | head -1)"

step "[2/4] 配置..."
id ${NE_USER} &>/dev/null || { groupadd ${NE_USER} 2>/dev/null || true; useradd -r -g ${NE_USER} -s /bin/false ${NE_USER} 2>/dev/null || true; }
chown -R ${NE_USER}:${NE_USER} "${NE_HOME}"

step "[3/4] systemd..."
cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter ${NE_VERSION}
After=network.target
[Service]
Type=simple
User=${NE_USER}
Group=${NE_USER}
ExecStart=${NE_HOME}/node_exporter --web.listen-address=:${NE_PORT}
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable node_exporter; systemctl start node_exporter; sleep 2
systemctl is-active node_exporter &>/dev/null || { warn "  启动失败"; err "Node Exporter 启动失败"; }
info "  ✓ node_exporter 已启动 + 开机自启"

step "[4/4] 完成"
firewall-cmd --add-port=${NE_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
echo "============================================"
echo "  Node Exporter ${NE_VERSION} 安装完成"
echo "  端口: ${NE_PORT}"
echo "  Prometheus 配置中加入此节点即可采集"
echo "============================================"
