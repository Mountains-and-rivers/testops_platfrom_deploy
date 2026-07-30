#!/bin/bash
# ============================================================
# Harbor 安装启动
# 前提: 先执行 build_local.sh 构建本地镜像
# 用法: bash install_harbor.sh [版本] [域名/IP] [admin密码] [镜像仓库]
# ============================================================
set -euo pipefail

HARBOR_VER="${1:-2.11.0}"
HARBOR_DOMAIN="${2:-harbor.testops.local}"
ADMIN_PASS="${3:-Harbor12345}"
REGISTRY="${4:-harbor.testops.local/testops}"
INSTALL_DIR="${INSTALL_DIR:-/opt/harbor}"
DATA_DIR="${DATA_DIR:-/data/harbor}"
BUILD_DIR="${BUILD_DIR:-/opt/build/harbor}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

echo "============================================"
echo "  Harbor ${HARBOR_VER} 安装启动"
echo "  域名:      ${HARBOR_DOMAIN}"
echo "  镜像仓库:  ${REGISTRY}"
echo "============================================"

# ---- 0. 环境检查 ----
step "[0/7] 环境检查..."
FAILED=0
command -v docker &>/dev/null && info "  Docker" || { warn "  Docker 未安装"; FAILED=1; }
systemctl is-active docker &>/dev/null || { systemctl start docker; systemctl enable docker; }
if docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
    info "  Docker Compose"
elif docker-compose version &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
    info "  Docker Compose (独立版)"
else
    warn "  Docker Compose"; FAILED=1
fi
docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${REGISTRY}/harbor-core:${HARBOR_VER}" \
    && info "  本地镜像 ${REGISTRY}/harbor-core:${HARBOR_VER}" \
    || { warn "  本地镜像不存在，请先执行 build_local.sh"; FAILED=1; }
[ $FAILED -eq 1 ] && err "依赖检查未通过"

# ---- 1. 证书 ----
step "[1/7] 生成证书..."
mkdir -p "${DATA_DIR}/certs" /data/secret/cert
if [ -f "/data/secret/cert/server.crt" ] && [ -f "/data/secret/cert/server.key" ]; then
    info "  证书已存在"
else
    openssl req -newkey rsa:4096 -nodes -sha256 \
        -keyout "${DATA_DIR}/certs/harbor.key" \
        -x509 -days 3650 -out "${DATA_DIR}/certs/harbor.crt" \
        -subj "/CN=${HARBOR_DOMAIN}" \
        -addext "subjectAltName=DNS:${HARBOR_DOMAIN},IP:${HARBOR_DOMAIN},DNS:localhost,IP:127.0.0.1" 2>/dev/null
    cp "${DATA_DIR}/certs/harbor.crt" /data/secret/cert/server.crt
    cp "${DATA_DIR}/certs/harbor.key" /data/secret/cert/server.key
    chmod 644 /data/secret/cert/server.crt /data/secret/cert/server.key
    info "  已生成"
fi
# 修复 DB 数据目录权限（PostgreSQL 容器 UID=999 需写权限）
mkdir -p "${DATA_DIR}/database" /data/registry
chmod 777 "${DATA_DIR}/database" 2>/dev/null || true

# ---- 2. 配置 harbor.yml ----
step "[2/7] 配置 harbor.yml..."
[ -d "${INSTALL_DIR}" ] && warn "  ${INSTALL_DIR} 已存在，覆盖" && rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
[ -f "${BUILD_DIR}/make/harbor.yml.tmpl" ] \
    && cp "${BUILD_DIR}/make/harbor.yml.tmpl" "${INSTALL_DIR}/harbor.yml.tmpl" \
    || err "模板文件不存在: ${BUILD_DIR}/make/harbor.yml.tmpl（请先在同一机器上执行 build_local.sh）"
cd "${INSTALL_DIR}"
cp harbor.yml.tmpl harbor.yml
sed -i "s/hostname: reg.mydomain.com/hostname: ${HARBOR_DOMAIN}/" harbor.yml
sed -i "s|certificate: .*|certificate: ${DATA_DIR}/certs/harbor.crt|" harbor.yml
sed -i "s|private_key: .*|private_key: ${DATA_DIR}/certs/harbor.key|" harbor.yml
sed -i "s/harbor_admin_password: .*/harbor_admin_password: ${ADMIN_PASS}/" harbor.yml
sed -i "s|data_volume: /data/|data_volume: ${DATA_DIR}|" harbor.yml
sed -i "s|goharbor/|${REGISTRY}/|g" harbor.yml
info "  harbor.yml 就绪"

# ---- 3. 生成 docker-compose（prepare）----
step "[3/7] 生成 docker-compose.yml..."
mkdir -p input common/config
cp harbor.yml input/
docker run --rm --entrypoint python3 \
    -v "${INSTALL_DIR}/input:/input" \
    -v "${DATA_DIR}:/data" \
    -v "${INSTALL_DIR}:/compose_location" \
    -v "${INSTALL_DIR}/common/config:/config" \
    -v "/:/hostfs" \
    "goharbor/prepare:v${HARBOR_VER}" main.py prepare 2>&1 | tail -5
[ -f docker-compose.yml ] || err "docker-compose.yml 生成失败"
info "  docker-compose.yml 已生成"

# prepare 可能把 private_key.pem 创建为目录，或生成格式不对——强制重新生成
info "  生成 RSA 私钥..."
rm -rf /data/secret/core/private_key.pem
openssl genrsa -traditional -out /data/secret/core/private_key.pem 4096
chmod 644 /data/secret/core/private_key.pem

# ---- 4. 修复兼容性问题 ----
step "[4/7] 修复配置兼容性..."
# 修复 PostgreSQL 主机名（prepare 生成的是 "postgresql"，实际服务名是 harbor-db）
if [ -f common/config/core/env ]; then
    sed -i 's|POSTGRESQL_HOST=postgresql|POSTGRESQL_HOST=harbor-db|' common/config/core/env
fi
# 修复镜像名称（prepare 生成 Photon 命名，替换为实际镜像名）
sed -i "s|goharbor/registry-photon:v${HARBOR_VER}|goharbor/harbor-registry:v${HARBOR_VER}|g" docker-compose.yml
sed -i "s|goharbor/valkey-photon:v${HARBOR_VER}|goharbor/harbor-valkey:v${HARBOR_VER}|g" docker-compose.yml
sed -i "s|goharbor/redis-photon:v${HARBOR_VER}|goharbor/harbor-valkey:v${HARBOR_VER}|g" docker-compose.yml
sed -i "s|goharbor/trivy-adapter-photon:v${HARBOR_VER}|goharbor/harbor-trivy-adapter:v${HARBOR_VER}|g" docker-compose.yml
info "  已修复"

# ---- 5. 启动 ----
step "[5/7] 启动 Harbor..."

# postgres:15-alpine 默认只监听 localhost，需修复后 core 才能连接
# 先启动 db → 修配置 → 再启动全部服务
info "  修复 PostgreSQL 配置..."
${DOCKER_COMPOSE} down 2>/dev/null || true
${DOCKER_COMPOSE} up -d postgresql 2>&1 | tail -3
sleep 15

# 添加 listen_addresses（postgres:15-alpine 只监听 localhost）
PGDATA=$(docker exec harbor-db find /var/lib/postgresql/data -name postgresql.conf -type f 2>/dev/null | head -1)
if [ -n "${PGDATA}" ]; then
    docker exec harbor-db sh -c "echo listen_addresses = '*' >> ${PGDATA}" 2>/dev/null || true
fi

# 改认证为 trust（Docker 内部网络无需密码）
docker exec harbor-db sh -c "sed -i 's/scram-sha-256/trust/g; s/md5/trust/g; s/password/trust/g' /var/lib/postgresql/data/pg18/pg_hba.conf" 2>/dev/null || true

# 重启 db 使配置生效
docker restart harbor-db 2>&1 | tail -1 || true
sleep 10

# 创建 registry 数据库（postgres:15-alpine 不带 Harbor init 脚本）
docker exec harbor-db createdb -U postgres registry 2>/dev/null || true

# 启动全部服务
${DOCKER_COMPOSE} up -d 2>&1 | tail -10
info "  已启动"

# ---- 6. 等待就绪 ----
step "[6/7] 等待 Harbor 就绪..."
for i in $(seq 1 30); do
    if curl -sk --connect-timeout 3 "https://127.0.0.1" 2>/dev/null | grep -q 'Harbor'; then
        info "Harbor 就绪 (${i}/30)"; break
    fi
    [ $i -eq 30 ] && warn "超时，检查: cd ${INSTALL_DIR} && ${DOCKER_COMPOSE} ps" || sleep 5
done

# ---- 7. 验证 ----
step "[7/7] 启动后检查..."
${DOCKER_COMPOSE} ps 2>/dev/null | head -12
RUNNING=$(${DOCKER_COMPOSE} ps --status running -q 2>/dev/null | wc -l)
TOTAL=$(${DOCKER_COMPOSE} ps -q 2>/dev/null | wc -l)
[ ${TOTAL} -gt 0 ] && info "  容器: ${RUNNING}/${TOTAL} running"
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 "https://127.0.0.1" 2>/dev/null || echo "000")
case "${HTTP_CODE}" in
    200|302) info "  HTTP: ${HTTP_CODE}" ;;
    *)       warn "  HTTP: ${HTTP_CODE} (预期 200/302)" ;;
esac

echo ""
echo "============================================"
echo "  Harbor ${HARBOR_VER} 安装完成"
echo "  URL:      https://${HARBOR_DOMAIN}"
echo "  账号:     admin"
echo "  密码:     ${ADMIN_PASS}"
echo "============================================"
