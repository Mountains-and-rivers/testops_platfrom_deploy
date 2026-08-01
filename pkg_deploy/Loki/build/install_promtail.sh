#!/bin/bash
# ============================================================
# Promtail 3.x — 裸机日志采集 Agent（CentOS 9）
#
# 安装方式: 官方预编译二进制（源码编译 TODO）
# 本地优先: 脚本同目录 promtail-linux-amd64.zip
#
# 用法: bash install_promtail.sh [--loki-url http://127.0.0.1:3100]
# ============================================================
# TODO: 源码编译模式（预留）
# ═══════════════════════════════════════════════
set -euo pipefail; cd /tmp

PT_VERSION="${PT_VERSION:-3.4.0}"
PT_ZIP="promtail-linux-amd64.zip"
PT_URL="https://github.com/grafana/loki/releases/download/v${PT_VERSION}/${PT_ZIP}"
PT_HOME="${PT_HOME:-/opt/promtail}"
PT_USER="${PT_USER:-root}"
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100/loki/api/v1/push}"
DATA_DIR="${DATA_DIR:-/data/promtail}"
# 采集路径
LOG_PATHS="${LOG_PATHS:-/var/log/*.log /var/log/messages}"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname)}"

while [[ $# -gt 0 ]]; do case "$1" in --loki-url) LOKI_URL="$2"; shift 2;; --source) echo "源码编译 TODO"; exit 0;; *) shift;; esac; done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Promtail ${PT_VERSION} 日志采集 Agent"
echo "  Loki: ${LOKI_URL}"
echo "============================================"

step "[0/4] 检查..."
[ -x "${PT_HOME}/promtail-linux-amd64" ] && { ver=$(${PT_HOME}/promtail-linux-amd64 --version 2>&1 | head -1); info "  已安装: ${ver}"; exit 0; }
systemctl stop promtail 2>/dev/null || true

step "[1/4] 获取..."
if _PKG=$(get_local "${PT_ZIP}"); then info "  使用本地: $(basename ${_PKG})"; cp "${_PKG}" "/tmp/${PT_ZIP}"
else info "  下载: ${PT_URL}"; wget -q --show-progress -O "/tmp/${PT_ZIP}" "${PT_URL}" 2>/dev/null || curl -L -o "/tmp/${PT_ZIP}" "${PT_URL}" || err "下载失败"
     mkdir -p /tmp/build-cache && cp "/tmp/${PT_ZIP}" "/tmp/build-cache/${PT_ZIP}" 2>/dev/null || true; fi
rm -rf "${PT_HOME}"; mkdir -p "${PT_HOME}"
unzip -o "/tmp/${PT_ZIP}" -d "${PT_HOME}" 2>&1 | tail -1 || err "解压失败"
chmod +x "${PT_HOME}/promtail-linux-amd64"; rm -f "/tmp/${PT_ZIP}"
info "  ✓ Promtail v${PT_VERSION}"

step "[2/4] 配置..."
mkdir -p "${DATA_DIR}"
# 构建日志采集 job 列表
cat > "${PT_HOME}/config.yaml" << EOF
server:
  http_listen_port: 0
  grpc_listen_port: 0

positions:
  filename: ${DATA_DIR}/positions.yaml

clients:
  - url: ${LOKI_URL}

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: ${HOSTNAME_LABEL}
          __path__: /var/log/*.log
  - job_name: journal
    journal:
      json: false
      max_age: 12h
      labels:
        job: journal
        host: ${HOSTNAME_LABEL}
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: 'unit'
EOF
info "  ✓ config.yaml → ${PT_HOME}/config.yaml"

step "[3/4] systemd..."
cat > /etc/systemd/system/promtail.service << EOF
[Unit]
Description=Promtail ${PT_VERSION} - Log Collector
After=network.target
[Service]
Type=simple
ExecStart=${PT_HOME}/promtail-linux-amd64 -config.file=${PT_HOME}/config.yaml
Restart=on-failure; RestartSec=15
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable promtail; systemctl start promtail; sleep 3
systemctl is-active promtail &>/dev/null || { warn "  启动失败: journalctl -u promtail -n 20"; err "Promtail 启动失败"; }
info "  ✓ promtail 已启动 + 开机自启"

step "[4/4] 完成"
echo "============================================"
echo "  Promtail ${PT_VERSION} 安装完成"
echo "  Loki: ${LOKI_URL}"
echo "  管理: systemctl {start|stop|restart} promtail"
echo "============================================"
