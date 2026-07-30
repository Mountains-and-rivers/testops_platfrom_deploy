#!/bin/bash
# ============================================================
# Jenkins Docker 镜像构建（源码→容器，一键）
#
# 用法:
#   bash build_image.sh                           # 默认: Docker 内全量编译
#   bash build_image.sh --prebuilt                # 快速: 使用预编译 WAR
#   bash build_image.sh --prebuilt push           # 构建 + 推送
#   bash build_image.sh 2.479.1 --prebuilt        # 指定版本
#
# 前置:
#   --full 模式: 无需前置（Docker 内完成源码→编译）
#   --prebuilt 模式: 需先 bash build_jenkins.sh（产出 WAR）
#
# 产出:
#   harbor.testops.local/testops/jenkins:2.479.1
#   harbor.testops.local/testops/jenkins:latest
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$(pwd)")"

# ── 参数 ─────────────────────────────────────────────────
JENKINS_VERSION="${JENKINS_VERSION:-2.479.1}"
HARBOR_URL="${HARBOR_URL:-harbor.testops.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-testops}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
IMAGE_NAME="${IMAGE_NAME:-jenkins}"
JDK_VERSION="${JDK_VERSION:-21}"   # Jenkins 2.555+ 统一用 JDK 21
MODE="full"
PUSH=""

# ── JDK 版本自动匹配（与 build_jenkins.sh _detect_jdk 一致）──
# Jenkins 2.555+ → JDK 21, 2.463+ → JDK 17, 2.361+ → JDK 11
_detect_jdk_from_zip() {
    local zip="$1"
    [ -f "${zip}" ] || return 1
    # Jenkins pom.xml 使用 CI Friendly 变量: <revision>2.576</revision> + <changelist>-SNAPSHOT</changelist>
    local v; v=$(unzip -p "${zip}" "*/pom.xml" 2>/dev/null | grep -oP '<revision>\K[0-9.]+' | head -1)
    [ -z "${v}" ] && return 1
    local m; m=$(echo "${v}" | cut -d. -f1)
    local n; n=$(echo "${v}" | cut -d. -f2)
    if [ "${m}" -ge 3 ] || { [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 555 ]; }; then echo "21"
    elif [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 463 ]; then echo "17"
    elif [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 361 ]; then echo "11"
    else echo "11"; fi
    return 0
}

for arg in "${@}"; do
    case "${arg}" in
        --prebuilt) MODE="prebuilt" ;;
        --full)     MODE="full" ;;
        push)       PUSH="push" ;;
        *)          JENKINS_VERSION="${arg}" ;;
    esac
done

FULL_IMAGE="${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:${JENKINS_VERSION}"
LATEST_IMAGE="${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest"

# ── UI ──────────────────────────────────────────────────
readonly R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
info()  { echo -e "${G}[INFO]${N}  $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*"; }
step()  { echo -e "${C}[STEP]${N}  $*"; }
ok()    { echo -e "  ${G}[OK]${N} $*"; }
die()   { echo -e "\n${R}━━━━ ${BASH_SOURCE[0]}:${BASH_LINENO[0]} ━━━━${N}\n${R}  $*${N}\n"; exit 1; }
trap 'die "脚本异常退出 (exit=$?)"' ERR

echo ""
echo "============================================"
echo "  Jenkins ${JENKINS_VERSION} Docker 镜像构建"
echo "  模式: ${MODE}"
echo "  镜像: ${FULL_IMAGE}"
echo "============================================"
echo ""

# ── 1. Docker 检测 ─────────────────────────────────────
step "[1/6] Docker 环境..."
command -v docker &>/dev/null || die "Docker 未安装"
docker info &>/dev/null 2>&1 || { systemctl start docker 2>/dev/null || true; sleep 2; docker info &>/dev/null 2>&1 || die "Docker 未运行"; }
ok "Docker: $(docker --version)"

# ── 2. 基础镜像 ────────────────────────────────────────
step "[2/6] 基础镜像..."
if docker images centos:stream9 --format '{{.Tag}}' 2>/dev/null | grep -q .; then
    ok "centos:stream9 已缓存"
else
    warn "拉取 centos:stream9..."
    docker pull quay.io/centos/centos:stream9 2>/dev/null && docker tag quay.io/centos/centos:stream9 centos:stream9 \
        || docker pull centos:stream9 2>/dev/null \
        || die "centos:stream9 拉取失败"
    ok "centos:stream9 就绪"
fi

# ── 3. 准备构建上下文 ──────────────────────────────────
step "[3/6] 构建上下文..."
BUILD_CTX="/tmp/jenkins-docker-build-${JENKINS_VERSION}"
rm -rf "${BUILD_CTX}"; mkdir -p "${BUILD_CTX}"

# centos.repo（阿里云加速，无此文件时创建空占位防止 Docker COPY 失败）
CENTOS_REPO=""
for _src in "${SCRIPT_DIR}/../../harbor/build/centos.repo" "/opt/centos.repo"; do
    [ -f "${_src}" ] && { cp "${_src}" "${BUILD_CTX}/centos.repo"; CENTOS_REPO="${_src}"; break; }
done
if [ -z "${CENTOS_REPO}" ]; then
    warn "  未找到 centos.repo，Docker 将使用默认源（可能较慢）"
    touch "${BUILD_CTX}/centos.repo"
fi

if [ "${MODE}" = "prebuilt" ]; then
    # 快速模式: 复制预编译 WAR
    WAR_SRC="${JENKINS_WAR:-/opt/jenkins/jenkins.war}"
    [ -f "${WAR_SRC}" ] || die "WAR 不存在: ${WAR_SRC}\n  请先执行: bash build_jenkins.sh"
    cp "${WAR_SRC}" "${BUILD_CTX}/jenkins.war"
    ok "WAR: ${WAR_SRC} ($(du -h "${WAR_SRC}" | cut -f1))"

    cp "${SCRIPT_DIR}/Dockerfile.prebuilt" "${BUILD_CTX}/Dockerfile"
    cp "${SCRIPT_DIR}/docker-entrypoint.sh" "${BUILD_CTX}/"
    DOCKERFILE="${BUILD_CTX}/Dockerfile"
else
    # 全量编译: Docker 内完成一切
    info "  使用 Dockerfile (Docker 内编译)"

    # 搜索 Node tarball → 构建上下文（与 build_jenkins.sh 的 Maven 缓存预填充一致）
    # 保留原始文件名，Dockerfile 从中提取版本号
    node_found=""
    shopt -s nullglob
    for d in "${SCRIPT_DIR}" "${SCRIPT_DIR}/.." "/tmp/build-cache"; do
        [ -d "${d}" ] || continue
        for f in "${d}/"node-v*-linux-x64.tar.gz; do
            [ -f "${f}" ] && [ -s "${f}" ] || continue
            cp "${f}" "${BUILD_CTX}/"
            node_found="${f}"
            info "  Node: $(basename "${f}") → 构建上下文（跳过 Docker 内下载）"
            break 2
        done
    done
    shopt -u nullglob
    if [ -z "${node_found}" ]; then
        warn "  未找到 Node tarball，Docker 内将尝试在线下载（可能失败）"
        touch "${BUILD_CTX}/node-v0.0.0-linux-x64.tar.gz"  # 空占位，防止 COPY 通配失败
    fi

    # 搜索 jenkins.zip → 构建上下文（Docker 内无法访问 GitHub，使用本地源码）
    zip_found=""
    for d in "${SCRIPT_DIR}" "${SCRIPT_DIR}/.." "/tmp/build-cache"; do
        [ -d "${d}" ] || continue
        for _z in "jenkins-${JENKINS_VERSION}.zip" "jenkins.zip"; do
            [ -f "${d}/${_z}" ] && [ -s "${d}/${_z}" ] && { cp "${d}/${_z}" "${BUILD_CTX}/jenkins.zip"; zip_found="${d}/${_z}"; break 2; }
        done
    done
    if [ -n "${zip_found}" ]; then
        info "  源码: $(basename "${zip_found}") → 构建上下文"
        # 从 jenkins.zip 中的 pom.xml 检测实际 JDK 版本要求（与 build_jenkins.sh 一致）
        _detected_jdk=$(_detect_jdk_from_zip "${zip_found}" || echo "")
        if [ -n "${_detected_jdk}" ] && [ "${_detected_jdk}" != "${JDK_VERSION}" ]; then
            info "  JDK: pom.xml 要求 ${_detected_jdk}（参数默认 ${JDK_VERSION}），自动切换"
            JDK_VERSION="${_detected_jdk}"
        fi
    else
        die "  未找到 jenkins.zip 或 jenkins-${JENKINS_VERSION}.zip\n  请放到 ${SCRIPT_DIR} 或 /tmp/build-cache/"
    fi

    cp "${SCRIPT_DIR}/Dockerfile" "${BUILD_CTX}/"
    cp "${SCRIPT_DIR}/docker-entrypoint.sh" "${BUILD_CTX}/"
    DOCKERFILE="${BUILD_CTX}/Dockerfile"
fi
ok "构建上下文: ${BUILD_CTX}"

# ── 4. Docker 构建 ─────────────────────────────────────
step "[4/6] Docker 构建..."

# 清理旧镜像
docker rmi -f "${FULL_IMAGE}" "${LATEST_IMAGE}" 2>/dev/null || true

# 启用 BuildKit（支持 RUN --mount=type=cache 持久化 Maven 依赖缓存）
export DOCKER_BUILDKIT=1

docker build --no-cache \
    --build-arg "JENKINS_VERSION=${JENKINS_VERSION}" \
    --build-arg "JDK_VERSION=${JDK_VERSION}" \
    -t "${FULL_IMAGE}" \
    -t "${LATEST_IMAGE}" \
    -f "${DOCKERFILE}" \
    "${BUILD_CTX}" \
    || die "Docker 构建失败"

ok "镜像: ${FULL_IMAGE}"
ok "镜像: ${LATEST_IMAGE}"

# ── 5. 本地验证 ────────────────────────────────────────
step "[5/6] 本地验证..."
docker rm -f jenkins-verify 2>/dev/null || true
if docker run -d --name jenkins-verify -p 18080:8080 "${FULL_IMAGE}" 2>/dev/null; then
    info "  等待启动..."
    for i in $(seq 1 15); do
        curl -sf http://localhost:18080/login >/dev/null 2>&1 && { ok "HTTP 验证通过 (${i}/15)"; break; }
        sleep 3
    done
    docker rm -f jenkins-verify 2>/dev/null || true
else
    warn "  本地验证跳过"
fi

# ── 6. 推送（可选）──────────────────────────────────────
step "[6/6] 推送..."
if [ "${PUSH}" = "push" ]; then
    if [ -n "${HARBOR_PASS}" ]; then
        echo "${HARBOR_PASS}" | docker login "${HARBOR_URL}" -u "${HARBOR_USER}" --password-stdin 2>/dev/null || true
    else
        docker login "${HARBOR_URL}" -u "${HARBOR_USER}" || true
    fi
    docker push "${FULL_IMAGE}" && ok "推送: ${FULL_IMAGE}"
    docker push "${LATEST_IMAGE}" && ok "推送: ${LATEST_IMAGE}"
else
    info "  跳过（加 push 参数推送: bash build_image.sh --prebuilt push）"
fi

# ── 清理 ────────────────────────────────────────────────
rm -rf "${BUILD_CTX}"

echo ""
echo "============================================"
echo "  Jenkins ${JENKINS_VERSION} 镜像构建完成"
echo ""
echo "  镜像: ${FULL_IMAGE}"
echo "  镜像: ${LATEST_IMAGE}"
echo ""
echo "  启动容器:"
echo "    docker run -d --name jenkins \\"
echo "      -p 8080:8080 -p 50000:50000 \\"
echo "      -v jenkins_home:/var/lib/jenkins \\"
echo "      ${FULL_IMAGE}"
echo "============================================"
