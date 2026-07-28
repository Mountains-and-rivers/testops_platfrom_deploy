#!/bin/bash
# ============================================================
# Harbor 卸载清理
# 用法: bash clean_harbor.sh [--data]
#   --data   含持久化数据 /data/harbor
# ============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/harbor}"
BUILD_DIR="${BUILD_DIR:-/opt/build/harbor}"
DATA_DIR="${DATA_DIR:-/data/harbor}"
GO_DIR="/usr/local/go"
REMOVE_DATA=false

[ "${1:-}" = "--data" ] && REMOVE_DATA=true

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  Harbor 卸载"
echo "  安装目录: ${INSTALL_DIR}"
echo "  构建目录: ${BUILD_DIR}"
echo "  数据目录: ${DATA_DIR}"
${REMOVE_DATA} && echo "  数据: 删除" || echo "  数据: 保留"
echo "============================================"

# ---- 1. 停止并删除所有 Harbor 容器 ----
step "[1/8] 停止 Harbor 容器..."
if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
    cd "${INSTALL_DIR}"
    docker compose down -v 2>/dev/null || docker-compose down -v 2>/dev/null || true
fi
# 强制删除可能残留的 Harbor 容器
docker rm -f nginx harbor-core harbor-portal harbor-jobservice \
    registry registryctl harbor-db redis harbor-log harbor-valkey \
    2>/dev/null || true
info "已停止"

# ---- 2. 目录 ----
step "[2/8] 目录..."
[ -d "${INSTALL_DIR}" ] && rm -rf "${INSTALL_DIR}" && info "${INSTALL_DIR}" || true
[ -d "${BUILD_DIR}" ]     && rm -rf "${BUILD_DIR}"     && info "${BUILD_DIR}"     || true
[ -d "${GO_DIR}" ]        && rm -rf "${GO_DIR}"        && info "${GO_DIR}"        || true
[ -d /data/secret ]       && rm -rf /data/secret       && info "/data/secret"     || true

# ---- 3. 临时文件 ----
step "[3/8] 临时文件..."
rm -rf /tmp/harbor_extract /tmp/harbor_cfg /tmp/harbor-pkg \
    /tmp/harbor-src-* /tmp/harbor-offline-installer-* \
    /tmp/harbor-base-build /tmp/harbor-photon-build /tmp/harbor-test \
    /tmp/Dockerfile.* /tmp/centos.repo \
    /tmp/go*.tar.gz /tmp/node-*.tar.xz /tmp/dpkg_*.tar.xz \
    /tmp/spectral-linux-x64 /tmp/build-cache \
    2>/dev/null || true
info "临时文件"

# ---- 4. Harbor 组件镜像 ----
step "[4/8] Harbor 组件镜像..."
docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | \
    grep -iE 'goharbor|testops.*harbor|testops.*nginx|testops.*prepare|testops.*registry|testops.*valkey|testops.*trivy' | \
    xargs -r docker rmi -f 2>/dev/null || true
info "组件镜像"

# ---- 5. 编译镜像 ----
step "[5/8] 编译镜像..."
docker rmi -f golang:1.26.4 node:22.22.3 2>/dev/null || true
info "编译镜像"

# ---- 6. 外部拉取镜像 ----
step "[6/8] 外部镜像..."
docker rmi -f \
    registry:2 postgres:15-alpine valkey/valkey:9-alpine \
    centos:stream9 quay.io/centos/centos:stream9 \
    hello-world:latest alpine:latest \
    2>/dev/null || true
info "外部镜像"

# ---- 7. 清理悬空镜像和构建缓存 ----
step "[7/8] 悬空镜像 + 构建缓存..."
docker image prune -a -f 2>/dev/null || true
docker builder prune -a -f 2>/dev/null || true
docker container prune -f 2>/dev/null || true
docker network prune -f 2>/dev/null || true
info "已清理"

# ---- 8. 数据和端口 ----
step "[8/8] 数据 + 防火墙..."
if ${REMOVE_DATA}; then
    [ -d "${DATA_DIR}" ] && rm -rf "${DATA_DIR}" && info "${DATA_DIR}" || true
else
    info "保留 ${DATA_DIR}（--data 可删除）"
fi
for p in 80 443 4443; do
    firewall-cmd --remove-port=${p}/tcp --permanent 2>/dev/null || true
done
firewall-cmd --reload 2>/dev/null || true

echo ""
echo "============================================"
echo "  Harbor 卸载完成"
echo "============================================"
