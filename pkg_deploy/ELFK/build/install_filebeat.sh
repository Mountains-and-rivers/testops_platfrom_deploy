#!/bin/bash
# ============================================================
# Filebeat 8.17 — 裸机单机部署（CentOS 9）
#
# 安装方式: 官方预编译二进制 tar.gz（源码编译 TODO）
# 本地优先: 脚本同目录 filebeat-*.tar.gz
#
# 用法: bash install_filebeat.sh [--es-host 127.0.0.1:9200] [--ls-host 127.0.0.1:5044]
# ============================================================
# TODO: 源码编译模式（预留）
# ═══════════════════════════════════════════════
set -euo pipefail; cd /tmp

FB_VERSION="${FB_VERSION:-8.17.0}"
FB_TAR="filebeat-${FB_VERSION}-linux-x86_64.tar.gz"
FB_URL="https://artifacts.elastic.co/downloads/beats/filebeat/${FB_TAR}"
FB_HOME="${FB_HOME:-/opt/filebeat}"
FB_USER="${FB_USER:-root}"
ES_HOST="${ES_HOST:-127.0.0.1:9200}"
LS_HOST="${LS_HOST:-127.0.0.1:5044}"
OUTPUT_TYPE="${OUTPUT_TYPE:-elasticsearch}"  # elasticsearch | logstash
LOG_DIR="${LOG_DIR:-/var/log/filebeat}"
DATA_DIR="${DATA_DIR:-/data/filebeat}"
# 日志采集路径（空格分隔多个路径）
LOG_PATHS="${LOG_PATHS:-/var/log/*.log /var/log/messages}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --es-host) ES_HOST="$2"; shift 2 ;;
        --ls-host) LS_HOST="$2"; shift 2 ;;
        --output)  OUTPUT_TYPE="$2"; shift 2 ;;
        --paths)   LOG_PATHS="$2"; shift 2 ;;
        --source)  echo "源码编译 TODO"; exit 0 ;;
        *) shift ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Filebeat ${FB_VERSION} 单机部署"
echo "  输出: ${OUTPUT_TYPE}  |  ES: ${ES_HOST}  |  LS: ${LS_HOST}"
echo "============================================"

step "[0/4] 检查..."
[ -x "${FB_HOME}/filebeat" ] && { ver=$(${FB_HOME}/filebeat version 2>&1 | head -1); info "  已安装: ${ver}"; exit 0; }
systemctl stop filebeat 2>/dev/null || true

step "[1/4] 获取..."
if _PKG=$(get_local "${FB_TAR}"); then info "  使用本地: $(basename ${_PKG})"; cp "${_PKG}" "/tmp/${FB_TAR}"
else info "  下载: ${FB_URL}"; wget -q --show-progress -O "/tmp/${FB_TAR}" "${FB_URL}" 2>/dev/null || curl -L -o "/tmp/${FB_TAR}" "${FB_URL}" || err "下载失败"
     mkdir -p /tmp/build-cache && cp "/tmp/${FB_TAR}" "/tmp/build-cache/${FB_TAR}" 2>/dev/null || true; fi
rm -rf "${FB_HOME}"; tar -xzf "/tmp/${FB_TAR}" -C /opt; mv /opt/filebeat-* "${FB_HOME}"; rm -f "/tmp/${FB_TAR}"
info "  ✓ $(${FB_HOME}/filebeat version 2>&1)"

step "[2/4] 配置..."
mkdir -p "${LOG_DIR}" "${DATA_DIR}"
# 生成日志路径 YAML 列表
_PATHS_YAML=""; for p in ${LOG_PATHS}; do _PATHS_YAML="${_PATHS_YAML}    - ${p}\n"; done
cat > "${FB_HOME}/filebeat.yml" << EOF
filebeat.inputs:
- type: log
  enabled: true
  paths:
$(echo -e "${_PATHS_YAML}")

output.${OUTPUT_TYPE}:
EOF
if [ "${OUTPUT_TYPE}" = "elasticsearch" ]; then
    cat >> "${FB_HOME}/filebeat.yml" << EOF
  hosts: ["${ES_HOST}"]
EOF
else
    cat >> "${FB_HOME}/filebeat.yml" << EOF
  hosts: ["${LS_HOST}"]
EOF
fi
info "  ✓ filebeat.yml → ${FB_HOME}/filebeat.yml"

step "[3/4] systemd..."
cat > /etc/systemd/system/filebeat.service << EOF
[Unit]
Description=Filebeat ${FB_VERSION}
After=network.target
[Service]
Type=simple
ExecStart=${FB_HOME}/filebeat -e -c ${FB_HOME}/filebeat.yml
Restart=on-failure
RestartSec=15
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable filebeat; systemctl start filebeat; sleep 3
systemctl is-active filebeat &>/dev/null || { warn "  启动失败: journalctl -u filebeat -n 20"; err "Filebeat 启动失败"; }
info "  ✓ filebeat 已启动 + 开机自启"

step "[4/4] 完成"
echo "============================================"
echo "  Filebeat ${FB_VERSION} 安装完成"
echo "  输出: ${OUTPUT_TYPE} → ES:${ES_HOST} / LS:${LS_HOST}"
echo "  管理: systemctl {start|stop|restart} filebeat"
echo "============================================"
