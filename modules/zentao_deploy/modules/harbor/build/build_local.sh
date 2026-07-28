#!/bin/bash
# ============================================================
# Harbor 源码编译 + Docker 镜像构建 — 方案2：本地基础镜像（离线/内网）
#
# 适用场景: 目标机器无外网，或无法拉取 Docker Hub 官方镜像
# 前提:    先执行 build_base.sh 构建 goharbor/photon:5.0（基于 CentOS 9）
#          build_local.sh 自动检测基础镜像，不存在则调 build_base.sh
#
# 原理:    build_base.sh 已将 harbor-base:centos9 打标签为 goharbor/photon:5.0
#          Harbor 源码中 FROM goharbor/photon:5.0 直接使用我们的本地镜像
#          不需要替换 FROM，只需要修 tdnf→dnf 和 Photon 兼容性
#
# 用法: bash build_local.sh [版本] [镜像仓库] [push]
# 示例: bash build_local.sh 2.11.0 harbor.testops.local/testops push
# ============================================================
set -euo pipefail

HARBOR_VER="${1:-2.11.0}"
REGISTRY="${2:-harbor.testops.local/testops}"
BUILD_DIR="${BUILD_DIR:-/opt/build/harbor}"
GO_DIR="/usr/local/go"
GO_BIN="${GO_DIR}/bin/go"
HARBOR_REPO="https://github.com/goharbor/harbor.git"
BASE_IMAGE="harbor-base:centos9"
PHOTON_IMAGE="goharbor/photon:5.0"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

# 本地镜像加载: 脚本同目录 .tar 文件优先 docker load
load_local_image() {
    local tar_file="$1"
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
echo "  Harbor ${HARBOR_VER} 源码编译 + 镜像构建"
echo "  构建目录:  ${BUILD_DIR}"
echo "  目标仓库:  ${REGISTRY}"
echo "============================================"

# ---- 0. 环境检查 ----
step "[0/9] 环境检查..."
FAILED=0

command -v docker &>/dev/null && info "  ✓ Docker $(docker --version 2>&1 | awk '{print $3}' | cut -d- -f1)" || {
    warn "  安装 Docker..."
    dnf install -y docker-ce docker-ce-cli containerd.io 2>/dev/null \
        || dnf install -y docker 2>/dev/null \
        || { warn "  ✗ Docker 安装失败"; FAILED=1; }
}
systemctl is-active docker &>/dev/null || { systemctl start docker; systemctl enable docker; }

command -v git  &>/dev/null && info "  ✓ Git $(git --version 2>&1 | awk '{print $3}')" \
    || { dnf install -y git 2>/dev/null || { warn "  ✗ Git"; FAILED=1; }; }

command -v make &>/dev/null && info "  ✓ Make $(make --version 2>&1 | head -1)" \
    || { dnf install -y make 2>/dev/null || { warn "  ✗ Make"; FAILED=1; }; }

# Go — 优先用预编译二进制，没有则下载官方包
if [ -x "${GO_BIN}" ]; then
    info "  ✓ Go $(${GO_BIN} version 2>&1 | awk '{print $3}') (${GO_DIR})"
    export PATH="${GO_DIR}/bin:${PATH}"
elif command -v go &>/dev/null; then
    go env -w GOPROXY=https://goproxy.cn,direct 2>/dev/null || true
    go env -w GO111MODULE=on 2>/dev/null || true
    info "  ✓ Go $(go version 2>&1 | awk '{print $3}') (系统)"
else
    warn "  安装 Go..."
    GO_TGZ="go1.26.4.linux-amd64.tar.gz"
    # 优先本地: 脚本目录 → 缓存目录
    for d in "${_SCRIPT_DIR}/" "/tmp/build-cache/"; do
        [ -f "${d}${GO_TGZ}" ] && cp "${d}${GO_TGZ}" /tmp/ && info "  Go 使用本地: ${d}${GO_TGZ}" && break
    done
    # 本地没有则下载
    if [ ! -f "/tmp/${GO_TGZ}" ]; then
        wget -q --show-progress -O "/tmp/${GO_TGZ}" "https://go.dev/dl/${GO_TGZ}" \
            || curl -L -o "/tmp/${GO_TGZ}" "https://go.dev/dl/${GO_TGZ}" \
            || { warn "  ✗ Go 下载失败"; FAILED=1; }
    fi
    if [ $FAILED -eq 0 ]; then
        rm -rf "${GO_DIR}"
        tar -C /usr/local -xzf "/tmp/${GO_TGZ}"
        rm -f "/tmp/${GO_TGZ}"
        export PATH="${GO_DIR}/bin:${PATH}"
        go env -w GOPROXY=https://goproxy.cn,direct 2>/dev/null || true
        go env -w GO111MODULE=on 2>/dev/null || true
        info "  ✓ Go $(go version 2>&1 | awk '{print $3}') (${GO_DIR})"
    fi
fi

DISK_GB=$(df -BG /opt 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
[ -n "${DISK_GB}" ] && [ "${DISK_GB}" -ge 15 ] \
    && info "  ✓ 磁盘 ${DISK_GB}GB" \
    || { warn "  ✗ 磁盘空间 ${DISK_GB:-?}GB (建议 ≥ 15GB)"; FAILED=1; }

[ $FAILED -eq 1 ] && err "依赖检查未通过，请修复后重试"

# ---- 0-b. 确保基础镜像存在 ----
step "[0-b/9] 检查基础镜像 ${BASE_IMAGE}..."
if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${BASE_IMAGE}$"; then
    info "  ✓ ${BASE_IMAGE} 已存在"
else
    warn "  ${BASE_IMAGE} 不存在，自动构建..."
    BASED_SCRIPT="${_SCRIPT_DIR}/build_base.sh"
    if [ -f "${BASED_SCRIPT}" ]; then
        info "  调用: bash ${BASED_SCRIPT}"
        bash "${BASED_SCRIPT}" || err "基础镜像构建失败，请检查 build_base.sh"
    else
        err "未找到 build_base.sh，请先执行: bash build_base.sh"
    fi
fi

# 确保 photon 标签也存在
if ! docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${PHOTON_IMAGE}$"; then
    info "  补充 Photon 标签: ${PHOTON_IMAGE}"
    docker tag "${BASE_IMAGE}" "${PHOTON_IMAGE}"
fi

# ---- 1. 构建 golang:1.26.4（基于 harbor-base:centos9）----
step "[1/9] 构建 golang:1.26.4 (基于 ${BASE_IMAGE})..."
docker rmi -f golang:1.26.4 2>/dev/null || true

GO_ARCHIVE="go1.26.4.linux-amd64.tar.gz"
for d in "${_SCRIPT_DIR}/" "/tmp/build-cache/"; do
    [ -f "${d}${GO_ARCHIVE}" ] && cp "${d}${GO_ARCHIVE}" /tmp/ && info "  Go 使用本地: ${d}${GO_ARCHIVE}" && break
done
if [ ! -f "/tmp/${GO_ARCHIVE}" ]; then
    wget --show-progress -O "/tmp/${GO_ARCHIVE}" "https://go.dev/dl/${GO_ARCHIVE}" \
        || err "下载失败: https://go.dev/dl/${GO_ARCHIVE}"
fi

# Dockerfile.golang — 极简：仅添加 Go，依赖全由基础镜像提供
cat > /tmp/Dockerfile.golang << 'DOCKERFILE_GO'
FROM harbor-base:centos9

COPY go1.26.4.linux-amd64.tar.gz /tmp/
RUN echo ">>> 安装 Go..." && \
    tar -C /usr/local -xzf /tmp/go1.26.4.linux-amd64.tar.gz && \
    rm /tmp/go1.26.4.linux-amd64.tar.gz

ENV GOROOT=/usr/local/go \
    GOPATH=/go \
    GOPROXY=https://goproxy.cn,direct \
    GO111MODULE=on \
    GONOSUMCHECK=* \
    GONOSUMDB=* \
    GONOPROXY= \
    PATH=/usr/local/go/bin:/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN mkdir -p /go && go env GOPROXY && go env GOPATH && go version
DOCKERFILE_GO

docker build --progress=plain --no-cache -t golang:1.26.4 -f /tmp/Dockerfile.golang /tmp
rm -f /tmp/Dockerfile.golang "/tmp/${GO_ARCHIVE}"
info "  ✓ golang:1.26.4"

# ---- 2. 构建 node:22.22.3（基于 harbor-base:centos9）----
step "[2/9] 构建 node:22.22.3 (基于 ${BASE_IMAGE})..."
docker rmi -f node:22.22.3 2>/dev/null || true

NODE_ARCHIVE="node-v22.22.3-linux-x64.tar.xz"
for d in "${_SCRIPT_DIR}/" "/tmp/build-cache/"; do
    [ -f "${d}${NODE_ARCHIVE}" ] && cp "${d}${NODE_ARCHIVE}" /tmp/ && info "  Node 使用本地: ${d}${NODE_ARCHIVE}" && break
done
if [ ! -f "/tmp/${NODE_ARCHIVE}" ]; then
    wget --show-progress -O "/tmp/${NODE_ARCHIVE}" "https://nodejs.org/dist/v22.22.3/${NODE_ARCHIVE}" \
        || err "下载失败: https://nodejs.org/dist/v22.22.3/${NODE_ARCHIVE}"
fi

# Dockerfile.node — 极简：仅添加 Node.js
cat > /tmp/Dockerfile.node << 'DOCKERFILE_NODE'
FROM harbor-base:centos9

COPY node-v22.22.3-linux-x64.tar.xz /tmp/
RUN echo ">>> 安装 Node.js..." && \
    tar -C /usr/local --strip-components=1 -xJf /tmp/node-v22.22.3-linux-x64.tar.xz && \
    rm /tmp/node-v22.22.3-linux-x64.tar.xz

ENV NODE_PATH=/usr/local/lib/node_modules \
    NPM_CONFIG_REGISTRY=https://registry.npmmirror.com \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN node -v && npm -v && npm config get registry
DOCKERFILE_NODE

docker build --progress=plain --no-cache -t node:22.22.3 -f /tmp/Dockerfile.node /tmp
rm -f /tmp/Dockerfile.node "/tmp/${NODE_ARCHIVE}"
info "  ✓ node:22.22.3"

# ---- 3. 拉源码 ----
step "[3/9] 拉取 Harbor 源码..."
mkdir -p "$(dirname "${BUILD_DIR}")"

# 优先本地 zip → 已有 git 仓库 → git clone
if [ -f "${_SCRIPT_DIR}/harbor.zip" ]; then
    info "  解压本地: ${_SCRIPT_DIR}/harbor.zip"
    [ -d "${BUILD_DIR}" ] && rm -rf "${BUILD_DIR}"
    unzip -qo "${_SCRIPT_DIR}/harbor.zip" -d /tmp/harbor_extract
    EXTRACTED=$(ls /tmp/harbor_extract/ | head -1)
    if [ -d "/tmp/harbor_extract/${EXTRACTED}" ] && [ "$(ls -A /tmp/harbor_extract/ | wc -l)" -eq 1 ]; then
        mv "/tmp/harbor_extract/${EXTRACTED}" "${BUILD_DIR}"
    else
        mv /tmp/harbor_extract/* "${BUILD_DIR}" 2>/dev/null || mv /tmp/harbor_extract "${BUILD_DIR}"
    fi
    rm -rf /tmp/harbor_extract
    [ -f "${BUILD_DIR}/Makefile" ] || err "harbor.zip 解压异常，未找到 Makefile"
    # 修复 Windows zip 打包带来的 CRLF + 权限问题
    find "${BUILD_DIR}" -type f -name '*.sh' -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
    chmod -R +x "${BUILD_DIR}/make/" 2>/dev/null || true
    # Photon → CentOS 兼容修复（全部 Dockerfile 生效）
    find "${BUILD_DIR}" -name 'Dockerfile*' -exec sed -i \
        -e 's|tdnf |dnf |g' \
        -e '/photon-snapshot.repo/d' \
        -e 's|groupadd -g 999 |groupadd -f -g 999 |g' \
        -e 's|groupadd -r -g 10000 |groupadd -f -r -g 10000 |g' \
        {} \; 2>/dev/null || true
    info "  解压完成: ${BUILD_DIR}"
elif [ -d "${BUILD_DIR}/.git" ]; then
    cd "${BUILD_DIR}"
    git fetch --tags 2>/dev/null || true
    git checkout "v${HARBOR_VER}" 2>/dev/null || true
    info "  更新: ${BUILD_DIR}"
else
    [ -d "${BUILD_DIR}" ] && warn "  ${BUILD_DIR} 存在但非 git 仓库，删除重建" && rm -rf "${BUILD_DIR}"
    expect -c "
set timeout 300
spawn git clone --depth 1 --branch v${HARBOR_VER} ${HARBOR_REPO} ${BUILD_DIR}
expect {
    \"*yes/no*\"      { send \"yes\r\"; exp_continue }
    \"*fingerprint*\" { send \"yes\r\"; exp_continue }
    \"*Username*\"    { send \"Mountains-and-rivers\r\"; exp_continue }
    \"*Password*\"    { send \"Wgl,.2018\r\"; exp_continue }
    timeout           { exit 1 }
}
" 2>&1 || err "Git clone 失败: ${HARBOR_REPO}"
    info "  Clone: ${BUILD_DIR}"
fi
[ -d "${BUILD_DIR}" ] || err "BUILD_DIR 不存在: ${BUILD_DIR}"
cd "${BUILD_DIR}"
[ -f Makefile ] || err "Makefile 缺失，源码不完整"
# Photon → CentOS 兼容修复
find "${BUILD_DIR}" -name 'Dockerfile*' -exec sed -i \
    -e 's|tdnf |dnf |g' \
    -e '/photon-snapshot.repo/d' \
    -e 's|groupadd -g 999 |groupadd -f -g 999 |g' \
    -e 's|groupadd -r -g 10000 |groupadd -f -r -g 10000 |g' \
    {} \; 2>/dev/null || true

# ---- 4. 编译 Go 二进制 ----
step "[4/9] 编译 Go 二进制..."
go env GOPATH GOPROXY GOROOT 2>/dev/null || true
make compile VERSIONTAG="v${HARBOR_VER}" GOFLAGS="-mod=mod" -j$(nproc) \
    || err "编译失败（检查: 能否访问 goproxy.cn? vendor 目录是否缺失?）"

# ---- 5. 构建镜像 ----
step "[5/9] 构建 Docker 镜像..."

# 禁止 BuildKit 从 Registry 拉取基础镜像，强制使用本地
export BUILDKIT_NO_PULL=1

# 预构建 spectral 镜像（如本地有 binary 则跳过下载）
if [ -f "${_SCRIPT_DIR}/spectral-linux-x64" ] && ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^goharbor/spectral:v6.14.2$'; then
    info "  使用本地 spectral-linux-x64 构建镜像..."
    cp "${_SCRIPT_DIR}/spectral-linux-x64" /tmp/
    chmod +x /tmp/spectral-linux-x64
    docker build --no-cache -t goharbor/spectral:v6.14.2 -f - /tmp <<'DOCKERFILE_SPECTRAL'
FROM node:22.22.3
COPY spectral-linux-x64 /usr/bin/spectral
RUN chmod +x /usr/bin/spectral && spectral --version
DOCKERFILE_SPECTRAL
    rm -f /tmp/spectral-linux-x64
    info "  ✓ goharbor/spectral:v6.14.2"
fi

# 强制所有 docker build 加 --pull=false，禁止从 Docker Hub 拉取
find "${BUILD_DIR}" -name 'Makefile' -exec sed -i \
    -e 's|docker build |docker build --pull=false |g' \
    -e 's|--pull=false --pull=false|--pull=false|g' \
    {} \; 2>/dev/null || true
info "  已禁用 docker pull"

# 优先本地 tar 加载外部依赖镜像（否则 make build 会尝试拉取）
for tar_img in "valkey-9-alpine.tar" "registry-2.tar" "postgres-15-alpine.tar"; do
    load_local_image "${tar_img}" || true
done

make build VERSIONTAG="v${HARBOR_VER}" \
    BASEIMAGETAG="v${HARBOR_VER}" \
    PULL_BASE_FROM_DOCKERHUB="false" \
    || err "镜像构建失败"

# ---- 6. 打标签 ----
step "[6/9] 打本地标签..."
tagged=0
for img in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "^goharbor/.*:v${HARBOR_VER}" || true); do
    comp=$(echo "${img}" | cut -d/ -f2 | cut -d: -f1)
    docker tag "${img}" "${REGISTRY}/${comp}:${HARBOR_VER}"
    info "  ${comp} → ${REGISTRY}/${comp}:${HARBOR_VER}"
    tagged=$((tagged + 1))
done
[ $tagged -eq 0 ] && warn "未找到 goharbor 镜像，检查 make build 输出"

# ---- 7. 推送 ----
step "[7/9] 推送镜像..."
if [ "${3:-}" = "push" ]; then
    for img in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "^${REGISTRY}/.*:${HARBOR_VER}" || true); do
        docker push "${img}" || warn "推送失败: ${img}"
    done
else
    info "跳过（如需推送: bash build.sh ${HARBOR_VER} ${REGISTRY} push）"
fi

# ---- 8. 修复 prepare 镜像（htpasswd 缺失导致无法生成配置）----
step "[8/9] 修复 prepare 镜像..."
if docker images --format '{{.Tag}}' goharbor/prepare:v2.11.0 2>/dev/null | grep -q .; then
    info "  安装 htpasswd 到 prepare 镜像..."
    cat > /tmp/htpasswd.py << 'PYEOF'
import sys,hashlib,base64
u,p,f=sys.argv[-2],sys.argv[-1],sys.argv[-3]
h=base64.b64encode(hashlib.sha256(p.encode()).digest()).decode()
open(f,"w").write(u+":"+h+"\n")
PYEOF
    docker rm -f prepare-fix 2>/dev/null || true
    docker run -d --name prepare-fix --entrypoint sleep goharbor/prepare:v2.11.0 300
    sleep 2
    docker cp /tmp/htpasswd.py prepare-fix:/usr/local/bin/htpasswd
    docker exec prepare-fix chmod 755 /usr/local/bin/htpasswd
    docker exec prepare-fix sed -i 's|/usr/bin/htpasswd|/usr/local/bin/htpasswd|g' /usr/src/app/utils/registry.py
    docker commit prepare-fix goharbor/prepare:v2.11.0
    docker rm -f prepare-fix 2>/dev/null || true
    rm -f /tmp/htpasswd.py
    info "  prepare 已修复"
fi

# ---- 9. 构建后清理 ----
step "[9/9] 构建后清理..."
# 清理中间容器（make build 产生的临时容器）
docker container prune -f 2>/dev/null || true
# 清理悬空镜像（中间层、<none>:<none>）
docker image prune -f 2>/dev/null || true
# 清理构建缓存
docker builder prune -f 2>/dev/null || true
# 清理 /tmp 下的构建残留
rm -rf /tmp/harbor_extract /tmp/build-cache/harbor_extract 2>/dev/null || true
# 清理 go 编译缓存（可节省数 GB）
go clean -cache -modcache 2>/dev/null || true
info "  ✓ 清理完成"

# ---- 9. 完成 ----
step "[9/9] 完成"
echo ""
echo "============================================"
echo "  Harbor ${HARBOR_VER} 构建完成"
echo "  本地镜像:"
docker images --format '  {{.Repository}}:{{.Tag}}' 2>/dev/null | grep "${HARBOR_VER}" | grep -v goharbor || true
echo ""
echo "  下一步: bash install_harbor.sh ${HARBOR_VER} ${HARBOR_DOMAIN:-harbor.testops.local} ${ADMIN_PASS:-Harbor12345} ${REGISTRY}"
echo "============================================"
