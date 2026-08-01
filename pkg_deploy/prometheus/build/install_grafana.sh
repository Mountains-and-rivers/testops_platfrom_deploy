#!/bin/bash
# ============================================================
# Grafana 11.x — 裸机单机部署（CentOS 9）
#
# 安装方式: 官方预编译二进制 tar.gz（源码编译 TODO）
# 本地优先: 脚本同目录 grafana-*.tar.gz
# 模板制作: 见 README.md 中 Grafana Dashboard 模板教程
#
# 用法: bash install_grafana.sh [--port 3000] [--prom-url http://127.0.0.1:9090]
# ═══════════════════════════════════════════════
# TODO: 源码编译模式（预留）
#   - [ ] git clone https://github.com/grafana/grafana.git → yarn build
# ═══════════════════════════════════════════════
set -euo pipefail; cd /tmp

GF_VERSION="${GF_VERSION:-11.6.0}"
GF_TAR="grafana-${GF_VERSION}.linux-amd64.tar.gz"
GF_URL="https://dl.grafana.com/oss/release/${GF_TAR}"
GF_HOME="${GF_HOME:-/opt/grafana}"
GF_USER="${GF_USER:-grafana}"
GF_PORT="${GF_PORT:-3000}"
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100}"
DATA_DIR="${DATA_DIR:-/data/grafana}"
LOG_DIR="${LOG_DIR:-/var/log/grafana}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-Grafana123!@#}"

while [[ $# -gt 0 ]]; do case "$1" in --port) GF_PORT="$2"; shift 2;; --prom-url) PROM_URL="$2"; shift 2;; --source) echo "源码编译 TODO"; exit 0;; *) shift;; esac; done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Grafana ${GF_VERSION} 单机部署"
echo "  端口: ${GF_PORT}  |  Prometheus: ${PROM_URL}"
echo "============================================"

step "[0/5] 检查..."
[ -x "${GF_HOME}/bin/grafana" ] && { ver=$(${GF_HOME}/bin/grafana --version 2>&1); info "  已安装: ${ver}"; exit 0; }
systemctl stop grafana 2>/dev/null || true

step "[1/5] 获取..."
if _PKG=$(get_local "${GF_TAR}"); then info "  使用本地: $(basename ${_PKG})"; cp "${_PKG}" "/tmp/${GF_TAR}"
else info "  下载: ${GF_URL}"; wget -q --show-progress -O "/tmp/${GF_TAR}" "${GF_URL}" 2>/dev/null || curl -L -o "/tmp/${GF_TAR}" "${GF_URL}" || err "下载失败"
     mkdir -p /tmp/build-cache && cp "/tmp/${GF_TAR}" "/tmp/build-cache/${GF_TAR}" 2>/dev/null || true; fi
rm -rf "${GF_HOME}"; tar -xzf "/tmp/${GF_TAR}" -C /opt; mv /opt/grafana-v* "${GF_HOME}"; rm -f "/tmp/${GF_TAR}"
info "  ✓ $( ${GF_HOME}/bin/grafana --version 2>&1)"

step "[2/5] 配置..."
id ${GF_USER} &>/dev/null || { groupadd ${GF_USER} 2>/dev/null || true; useradd -r -g ${GF_USER} -s /bin/false ${GF_USER} 2>/dev/null || true; }
mkdir -p "${DATA_DIR}/dashboards" "${DATA_DIR}/provisioning/datasources" "${DATA_DIR}/provisioning/dashboards" "${LOG_DIR}"
chown -R ${GF_USER}:${GF_USER} "${GF_HOME}" "${DATA_DIR}" "${LOG_DIR}"

# 修改 grafana.ini
cat > "${GF_HOME}/conf/custom.ini" << EOF
[server]
http_port = ${GF_PORT}
http_addr = 0.0.0.0
[security]
admin_user = ${ADMIN_USER}
admin_password = ${ADMIN_PASS}
[paths]
data = ${DATA_DIR}
logs = ${LOG_DIR}
[log]
mode = console file
level = info
EOF

# 自动配置 Prometheus 数据源
cat > "${DATA_DIR}/provisioning/datasources/prometheus.yaml" << EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: ${PROM_URL}
    access: proxy
    isDefault: true
    editable: true
EOF

# Loki 数据源（如果 Loki 已安装）
if curl -sk --connect-timeout 2 "${LOKI_URL}/ready" &>/dev/null 2>&1; then
    cat > "${DATA_DIR}/provisioning/datasources/loki.yaml" << EOF
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    url: ${LOKI_URL}
    access: proxy
    editable: true
EOF
    info "  ✓ 自动添加 Loki 数据源"
fi

# 自动加载 dashboards 目录中的 JSON 模板
cat > "${DATA_DIR}/provisioning/dashboards/default.yaml" << EOF
apiVersion: 1
providers:
  - name: 'default'
    folder: ''
    type: file
    options:
      path: ${DATA_DIR}/dashboards
EOF

# 复制脚本同目录的 dashboard JSON 模板
if ls "${SCRIPT_DIR}/"*.json 2>/dev/null | head -1 >/dev/null; then
    cp "${SCRIPT_DIR}/"*.json "${DATA_DIR}/dashboards/" 2>/dev/null || true
    info "  ✓ Dashboard 模板已导入"
fi

chown -R ${GF_USER}:${GF_USER} "${DATA_DIR}" "${GF_HOME}/conf"
info "  ✓ 配置完成（数据源: Prometheus ${PROM_URL}）"

step "[3/5] systemd..."
cat > /etc/systemd/system/grafana.service << EOF
[Unit]
Description=Grafana ${GF_VERSION} - Analytics & Monitoring
After=network.target
[Service]
Type=simple; User=${GF_USER}; Group=${GF_USER}
ExecStart=${GF_HOME}/bin/grafana server --config=${GF_HOME}/conf/custom.ini \\
    --homepath=${GF_HOME}
Restart=on-failure; RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload; systemctl enable grafana; systemctl start grafana; sleep 5
systemctl is-active grafana &>/dev/null || { warn "  启动失败: journalctl -u grafana -n 30"; err "Grafana 启动失败"; }
info "  ✓ grafana 已启动 + 开机自启"

step "[4/5] 验证..."
PASS=0; pgrep -f grafana &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗"
ss -tlnp 2>/dev/null | grep -q ":${GF_PORT}" && { info "  ✓ 端口 ${GF_PORT} 已监听"; PASS=$((PASS+1)); } || warn "  ✗"
firewall-cmd --add-port=${GF_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
step "[5/5] 完成 (${PASS}/2)"

echo "============================================"
echo "  Grafana ${GF_VERSION} 安装完成"
echo "  访问:     http://<IP>:${GF_PORT}"
echo "  账号:     ${ADMIN_USER} / ${ADMIN_PASS}"
echo "  数据源:   ${PROM_URL}"
echo "  Dashboard: ${DATA_DIR}/dashboards/"
echo "============================================"
