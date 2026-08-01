#!/bin/bash
# ============================================================
# Elasticsearch 8.17 — 裸机单机部署（CentOS 9）
#
# 安装方式: 官方预编译二进制 tar.gz（源码编译 TODO）
# 本地优先: 脚本同目录 elasticsearch-*.tar.gz
#
# 用法:     bash install_elasticsearch.sh [--port 9200] [--cluster my-cluster]
# ============================================================
# TODO: 源码编译模式（预留）
#   - [ ] elasticsearch-8.x.tar.gz → ./gradlew assemble → 产出 tar.gz
# ═══════════════════════════════════════════════
set -euo pipefail

# 必须在 cd 之前计算脚本目录，否则相对路径 $0 会解析到 /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
cd /tmp

ES_VERSION="${ES_VERSION:-8.17.0}"
ES_TAR="elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz"
ES_URL="https://artifacts.elastic.co/downloads/elasticsearch/${ES_TAR}"
ES_HOME="${ES_HOME:-/opt/elasticsearch}"
ES_USER="${ES_USER:-elasticsearch}"
ES_PORT="${ES_PORT:-9200}"
ES_CLUSTER="${ES_CLUSTER:-my-cluster}"
ES_HEAP="${ES_HEAP:-2g}"
LOG_DIR="${LOG_DIR:-/var/log/elasticsearch}"
DATA_DIR="${DATA_DIR:-/data/elasticsearch}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)    ES_PORT="$2"; shift 2 ;;
        --cluster) ES_CLUSTER="$2"; shift 2 ;;
        --source)  echo "源码编译 TODO，暂不支持"; exit 0 ;;
        *) shift ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

get_local() { for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }; done; return 1; }

echo "============================================"
echo "  Elasticsearch ${ES_VERSION} 单机部署"
echo "  方式: 官方预编译二进制  |  端口: ${ES_PORT}"
echo "============================================"

# ═══ 0. 检测 ═══
step "[0/5] 检查..."
if [ -x "${ES_HOME}/bin/elasticsearch" ]; then
    ver=$(${ES_HOME}/bin/elasticsearch --version 2>&1 | head -1 || echo "?")
    info "  已安装: ${ver}"; systemctl is-active elasticsearch &>/dev/null || systemctl start elasticsearch 2>/dev/null || true
    info "  跳过安装"; exit 0
fi
systemctl stop elasticsearch 2>/dev/null || true

# ═══ 1. 获取 ═══
step "[1/5] 获取二进制包..."
if _PKG=$(get_local "${ES_TAR}"); then
    info "  使用本地: $(basename ${_PKG}) ($(du -h ${_PKG} | cut -f1))"
    cp "${_PKG}" "/tmp/${ES_TAR}"
else
    info "  下载: ${ES_URL}"
    wget -q --show-progress -O "/tmp/${ES_TAR}" "${ES_URL}" 2>/dev/null || curl -L -o "/tmp/${ES_TAR}" "${ES_URL}" || err "下载失败"
    mkdir -p /tmp/build-cache && cp "/tmp/${ES_TAR}" "/tmp/build-cache/${ES_TAR}" 2>/dev/null || true
fi

rm -rf "${ES_HOME}"
tar -xzf "/tmp/${ES_TAR}" -C /opt
mv /opt/elasticsearch-* "${ES_HOME}"
rm -f "/tmp/${ES_TAR}"
info "  ✓ $(${ES_HOME}/bin/elasticsearch --version 2>&1 | head -1)"

# ═══ 2. 配置 ═══
step "[2/5] 配置..."
id ${ES_USER} &>/dev/null || { groupadd ${ES_USER} 2>/dev/null || true; useradd -r -g ${ES_USER} -s /bin/false ${ES_USER} 2>/dev/null || true; }
mkdir -p "${LOG_DIR}" "${DATA_DIR}"; chown -R ${ES_USER}:${ES_USER} "${ES_HOME}" "${LOG_DIR}" "${DATA_DIR}"

# 从脚本同目录读取配置模板优先
if [ -f "${SCRIPT_DIR}/elasticsearch.yml" ]; then
    cp "${SCRIPT_DIR}/elasticsearch.yml" "${ES_HOME}/config/elasticsearch.yml"
    sed -i "s|{{ES_PORT}}|${ES_PORT}|g; s|{{ES_CLUSTER}}|${ES_CLUSTER}|g; s|{{DATA_DIR}}|${DATA_DIR}|g; s|{{LOG_DIR}}|${LOG_DIR}|g" "${ES_HOME}/config/elasticsearch.yml"
else
    cat > "${ES_HOME}/config/elasticsearch.yml" << EOF
cluster.name: ${ES_CLUSTER}
node.name: node-1
path.data: ${DATA_DIR}
path.logs: ${LOG_DIR}
network.host: 0.0.0.0
http.port: ${ES_PORT}
discovery.type: single-node
xpack.security.enabled: false
EOF
fi

# JVM 堆
sed -i "s/^-Xms.*/-Xms${ES_HEAP}/; s/^-Xmx.*/-Xmx${ES_HEAP}/" "${ES_HOME}/config/jvm.options" 2>/dev/null || true
info "  ✓ elasticsearch.yml → ${ES_HOME}/config/"

# ═══ 3. systemd ═══
step "[3/5] 配置 systemd..."
cat > /etc/systemd/system/elasticsearch.service << SYSTEMDEOF
[Unit]
Description=Elasticsearch ${ES_VERSION}
After=network.target
[Service]
Type=simple
User=${ES_USER}
Group=${ES_USER}
Environment=ES_HOME=${ES_HOME}
ExecStart=${ES_HOME}/bin/elasticsearch
Restart=on-failure
RestartSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity
[Install]
WantedBy=multi-user.target
SYSTEMDEOF
systemctl daemon-reload; systemctl enable elasticsearch; systemctl start elasticsearch; sleep 5
systemctl is-active elasticsearch &>/dev/null || { warn "  启动失败: journalctl -u elasticsearch -n 30"; err "Elasticsearch 启动失败"; }
info "  ✓ elasticsearch 已启动 + 开机自启"

# ═══ 4. 验证 ═══
step "[4/5] 验证..."
PASS=0
pgrep -f "elasticsearch" &>/dev/null && { info "  ✓ 进程运行中"; PASS=$((PASS+1)); } || warn "  ✗ 进程未运行"
ss -tlnp 2>/dev/null | grep -q ":${ES_PORT}" && { info "  ✓ 端口 ${ES_PORT} 已监听"; PASS=$((PASS+1)); } || warn "  ✗ 端口 ${ES_PORT} 未监听"
HTTP_CODE=$(curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ES_PORT}" 2>/dev/null || echo "000")
[ "${HTTP_CODE}" != "000" ] && { info "  ✓ HTTP ${HTTP_CODE}"; PASS=$((PASS+1)); } || warn "  ✗ HTTP 无响应"
firewall-cmd --add-port=${ES_PORT}/tcp --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true

step "[5/5] 完成 (${PASS}/3)"
echo "============================================"
echo "  Elasticsearch ${ES_VERSION} 安装完成"
echo "  端口: ${ES_PORT}  |  集群: ${ES_CLUSTER}"
echo "  管理: systemctl {start|stop|restart} elasticsearch"
echo "============================================"
