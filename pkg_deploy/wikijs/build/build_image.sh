#!/bin/bash
# ============================================================
# Wiki.js Docker 镜像构建（源码→容器，一键）
#
# 用法:
#   bash build_image.sh                    # 默认: 全量编译
#   bash build_image.sh --prebuilt         # 快速: 使用预编译产物（需先 build_wikijs.sh）
#   bash build_image.sh --prebuilt push    # 构建 + 推送
#   bash build_image.sh 2.5.0 --prebuilt   # 指定版本
#
# 产出:
#   harbor.testops.local/testops/wiki:latest
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$(pwd)")"

WIKI_VERSION="${WIKI_VERSION:-latest}"
HARBOR_URL="${HARBOR_URL:-harbor.testops.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-testops}"
IMAGE_NAME="${IMAGE_NAME:-wiki}"
MODE="full"
PUSH=""

for arg in "${@}"; do
    case "${arg}" in
        --prebuilt) MODE="prebuilt" ;;
        --full)     MODE="full" ;;
        push)       PUSH="push" ;;
        *)          WIKI_VERSION="${arg}" ;;
    esac
done

IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:${WIKI_VERSION}"

# ── UI ──
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  Wiki.js Docker 镜像构建"
echo "  模式: ${MODE}  |  版本: ${WIKI_VERSION}"
echo "  镜像: ${IMAGE_TAG}"
echo "============================================"

# ═══ 全量编译模式 ═══
if [ "${MODE}" = "full" ]; then
    step "[1/2] Docker 内全量编译..."
    docker build -f "${SCRIPT_DIR}/Dockerfile" \
        -t "${IMAGE_TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest" \
        "${SCRIPT_DIR}/.."
else
    # ═══ 预编译模式 ═══
    step "[1/2] 使用预编译产物..."
    [ -d /opt/wiki ] && [ -f /opt/wiki/package.json ] \
        || { echo "预编译产物不存在，请先执行 build_wikijs.sh"; exit 1; }
    docker build -f "${SCRIPT_DIR}/Dockerfile.prebuilt" \
        -t "${IMAGE_TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest" \
        "${SCRIPT_DIR}/.."
fi

info "✓ 镜像构建完成: ${IMAGE_TAG}"

# ═══ 推送 ═══
if [ "${PUSH}" = "push" ]; then
    step "[2/2] 推送到 Harbor..."
    if [ -n "${HARBOR_PASS:-}" ]; then
        echo "${HARBOR_PASS}" | docker login "${HARBOR_URL}" -u "${HARBOR_USER:-admin}" --password-stdin 2>/dev/null || true
    fi
    docker push "${IMAGE_TAG}"
    docker push "${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest"
    info "✓ 推送完成"
fi
