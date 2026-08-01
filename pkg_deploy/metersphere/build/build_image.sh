#!/bin/bash
# ============================================================
# MeterSphere Docker 镜像构建（源码→容器，一键）
#
# 用法:
#   bash build_image.sh                       # 默认: 全量编译
#   bash build_image.sh --prebuilt            # 快速: 使用预编译 JAR
#   bash build_image.sh --prebuilt push       # 构建 + 推送
#   bash build_image.sh v3.6.0 --prebuilt     # 指定版本
#
# 产出:
#   harbor.testops.local/testops/metersphere:latest
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$(pwd)")"

MS_VERSION="${MS_VERSION:-latest}"
HARBOR_URL="${HARBOR_URL:-harbor.testops.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-testops}"
IMAGE_NAME="${IMAGE_NAME:-metersphere}"
MODE="full"
PUSH=""

for arg in "${@}"; do
    case "${arg}" in
        --prebuilt) MODE="prebuilt" ;;
        --full)     MODE="full" ;;
        push)       PUSH="push" ;;
        *)          MS_VERSION="${arg}" ;;
    esac
done

IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:${MS_VERSION}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

echo "============================================"
echo "  MeterSphere Docker 镜像构建"
echo "  模式: ${MODE}  |  版本: ${MS_VERSION}"
echo "  镜像: ${IMAGE_TAG}"
echo "============================================"

if [ "${MODE}" = "full" ]; then
    step "[1/2] Docker 内全量编译..."
    docker build -f "${SCRIPT_DIR}/Dockerfile" \
        -t "${IMAGE_TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest" \
        "${SCRIPT_DIR}/.."
else
    step "[1/2] 使用预编译 JAR..."
    MS_JAR=$(find /opt/metersphere -name "metersphere*.jar" -not -name "*sources*" | head -1)
    [ -n "${MS_JAR}" ] && [ -f "${MS_JAR}" ] || { echo "预编译 JAR 不存在，请先执行 build_metersphere.sh"; exit 1; }
    docker build -f "${SCRIPT_DIR}/Dockerfile.prebuilt" \
        -t "${IMAGE_TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest" \
        "${SCRIPT_DIR}/.."
fi

info "✓ 镜像构建完成: ${IMAGE_TAG}"

if [ "${PUSH}" = "push" ]; then
    step "[2/2] 推送到 Harbor..."
    if [ -n "${HARBOR_PASS:-}" ]; then
        echo "${HARBOR_PASS}" | docker login "${HARBOR_URL}" -u "${HARBOR_USER:-admin}" --password-stdin 2>/dev/null || true
    fi
    docker push "${IMAGE_TAG}"
    docker push "${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest"
    info "✓ 推送完成"
fi
