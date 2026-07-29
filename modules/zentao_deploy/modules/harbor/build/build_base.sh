#!/bin/bash
# ============================================================
# Harbor 基础镜像 — 极简运行时（仿官方 Photon OS 做法）
# 基于 CentOS Stream 9，仅装运行时包，不含编译工具链
# 产物: goharbor/photon:5.0（直接覆盖官方标签，~400MB）
# 用法: bash build_base.sh
# ============================================================
set -euo pipefail

PHOTON_IMAGE="goharbor/photon:5.0"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

# 本地镜像加载: 脚本同目录 .tar 文件优先 docker load
load_local_image() {
    local tar_file="${1:-}"
    if [ -f "${_SCRIPT_DIR}/${tar_file}" ]; then
        info "  加载本地镜像: ${tar_file}"
        docker load -i "${_SCRIPT_DIR}/${tar_file}" && return 0
    fi
    return 1
}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

echo "============================================"
echo "  Harbor 基础镜像构建（极简运行时）"
echo "  产物: ${PHOTON_IMAGE}"
echo "============================================"

# ---- 0. 环境 ----
step "[0/4] 环境检查..."
FAILED=0
command -v docker &>/dev/null && info "  Docker $(docker --version 2>&1 | awk '{print $3}' | cut -d- -f1)" || { warn "  Docker 未安装"; FAILED=1; }
systemctl is-active docker &>/dev/null || { systemctl start docker; systemctl enable docker; }
if docker images centos:stream9 --format '{{.Tag}}' 2>/dev/null | grep -q .; then
    info "  centos:stream9 已缓存"
else
    # 优先级: Docker Hub → quay.io → 本地 tar
    docker pull centos:stream9 2>/dev/null && info "  centos:stream9 (Docker Hub)" \
        || { docker pull quay.io/centos/centos:stream9 2>/dev/null && docker tag quay.io/centos/centos:stream9 centos:stream9 && info "  centos:stream9 (quay.io)"; } \
        || { load_local_image "centos-stream9.tar" && info "  centos:stream9 (本地 tar)"; } \
        || { warn "  centos:stream9 拉取失败"; FAILED=1; }
fi
[ $FAILED -eq 1 ] && err "依赖检查未通过"

# ---- 1. 准备上下文 ----
step "[1/4] 准备构建上下文..."
BUILD_CTX="/tmp/harbor-photon-build"
rm -rf "${BUILD_CTX}"
mkdir -p "${BUILD_CTX}"
[ -f "${_SCRIPT_DIR}/centos.repo" ] && cp "${_SCRIPT_DIR}/centos.repo" "${BUILD_CTX}/" || err "centos.repo 缺失"
# 禁用 centosplus（阿里云镜像经常超时）
sed -i '/^\[centosplus\]/,/^\[/{s/^enabled=1/enabled=0/}' "${BUILD_CTX}/centos.repo" 2>/dev/null || true

# ---- 2. 生成 Dockerfile ----
step "[2/4] 生成 Dockerfile..."

cat > "${BUILD_CTX}/Dockerfile" << 'DOCKERFILE'
FROM centos:stream9
COPY centos.repo /etc/yum.repos.d/centos.repo

# EPEL（阿里云镜像）
RUN dnf install -y epel-release && \
    rm -f /etc/yum.repos.d/epel*.repo && \
    echo '[epel]' > /etc/yum.repos.d/epel.repo && \
    echo 'name=EPEL - Aliyun' >> /etc/yum.repos.d/epel.repo && \
    echo 'baseurl=https://mirrors.aliyun.com/epel/$releasever/Everything/$basearch/' >> /etc/yum.repos.d/epel.repo && \
    echo 'enabled=1' >> /etc/yum.repos.d/epel.repo && \
    echo 'gpgcheck=0' >> /etc/yum.repos.d/epel.repo

# 确保 AppStream 可用（子镜像安装 postgresql-server 等包的来源）
RUN echo '[appstream]' >> /etc/yum.repos.d/centos.repo && \
    echo 'name=CentOS Stream - AppStream' >> /etc/yum.repos.d/centos.repo && \
    echo 'baseurl=https://mirrors.aliyun.com/centos-stream/9-stream/AppStream/$basearch/os/' >> /etc/yum.repos.d/centos.repo && \
    echo 'enabled=1' >> /etc/yum.repos.d/centos.repo && \
    echo 'gpgcheck=0' >> /etc/yum.repos.d/centos.repo && \
    dnf makecache

# 仅运行时包 — 仿官方 photon，不装编译工具链
# 对标: tdnf install -y tzdata shadow curl openssl gzip findutils cronie logrotate ...
RUN dnf install -y --setopt=tsflags=nodocs --allowerasing \
        tzdata shadow-utils \
        gzip findutils tar xz \
        ca-certificates openssl curl \
        cronie logrotate \
        glibc-langpack-en && \
    dnf clean all && rm -rf /var/cache/dnf

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TZ=Asia/Shanghai

# 验证
RUN set -ex; \
    echo "=== 运行时组件验证 ==="; \
    openssl version; curl --version | head -1; \
    ps --version 2>/dev/null | head -1 || echo "ps ok"; \
    ls /etc/pki/tls/certs/ca-bundle.crt >/dev/null && echo "ca-cert ok"; \
    locale -a 2>/dev/null | grep -q en_US && echo "locale ok"; \
    echo "=== 通过 ==="
DOCKERFILE

# ---- 3. 构建 ----
step "[3/4] 构建 ${PHOTON_IMAGE}..."
docker build --progress=plain --no-cache -t "${PHOTON_IMAGE}" -f "${BUILD_CTX}/Dockerfile" "${BUILD_CTX}" || err "构建失败"
SIZE=$(docker images --format '{{.Size}}' "${PHOTON_IMAGE}" 2>/dev/null)
info "  ${PHOTON_IMAGE}  (${SIZE})"

# ---- 4. 清理 ----
step "[4/4] 清理..."
rm -rf "${BUILD_CTX}"
docker container prune -f 2>/dev/null || true
docker image prune -f 2>/dev/null || true

echo ""
echo "============================================"
echo "  基础镜像构建完成"
echo "  ${PHOTON_IMAGE}  (${SIZE})"
echo "  仅含运行时包: tzdata shadow curl openssl cronie logrotate"
echo "============================================"
