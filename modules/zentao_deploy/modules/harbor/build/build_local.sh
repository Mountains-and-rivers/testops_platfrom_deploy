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

# ════════════════════════════════════════════════════════════
# Photon → CentOS Dockerfile 兼容修复
# 用法: _apply_photon_fixes <源码目录>
# 设计: 直调 sed，不用 eval；逐文件检查→修复→验证；幂等可重入
# ════════════════════════════════════════════════════════════
_apply_photon_fixes() {
    local src_dir="$1"
    info "  Photon → CentOS Dockerfile 修复..."

    # 列出所有 Dockerfile（包括 .base 等变体）
    local all_files
    all_files=$(find "${src_dir}" -name 'Dockerfile*' -type f 2>/dev/null || true)
    [ -z "${all_files}" ] && { info "    ✓ 无 Dockerfile"; return 0; }

    local fixed=0 skipped=0
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        [ -f "${f}" ] || continue
        [ -r "${f}" ] || { warn "    无法读取: ${f#${src_dir}/}"; skipped=$((skipped + 1)); continue; }
        [ -w "${f}" ] || { warn "    无法写入: ${f#${src_dir}/}"; skipped=$((skipped + 1)); continue; }

        # 无条件修复（sed 幂等，不会破坏已修复的文件）
        info "    修复: ${f#${src_dir}/}"
        cp -a "${f}" "${f}.bak"

        # 直接 sed（不用 eval，每一行模式都是确定性的字符串）
        sed -i \
            -e 's|tdnf |dnf |g' \
            -e '/photon-snapshot\.repo/d' \
            -e '/photon-snapshot/d' \
            -e 's|rm /etc/cron.daily/logrotate|rm -f /etc/cron.daily/logrotate|g' \
            -e 's|postgresql18-server|postgresql-server|g' \
            -e 's|postgresql15-server|postgresql-server|g' \
            -e 's|postgresql18-contrib|postgresql-contrib|g' \
            -e 's|postgresql15-contrib|postgresql-contrib|g' \
            -e 's|postgresql18-devel|postgresql-devel|g' \
            -e 's|postgresql15-devel|postgresql-devel|g' \
            -e 's|/usr/pgsql/18/share/postgresql/|/usr/share/postgresql/|g' \
            -e 's|\(/usr/share/postgresql/postgresql.conf.sample\)|\1 \|\| true|g' \
            -e 's|/usr/pgsql/15/share/postgresql/|/usr/share/postgresql/|g' \
            -e 's|\(/usr/share/postgresql/postgresql.conf.sample\)|\1 \|\| true|g' \
            -e 's|groupadd -g 999 |groupadd -f -g 999 |g' \
            -e 's|groupadd -r -g 10000 |groupadd -f -r -g 10000 |g' \
            -e 's|groupadd -r postgres --gid=999|groupadd -r postgres|g' \
            -e 's|useradd -m -r -g postgres --uid=999 postgres|useradd -m -r -g postgres postgres|g' \
            -e 's|useradd -u 999 -g 999 |useradd -r -g 999 |g' \
            -e 's|useradd -r -c "Valkey|useradd -r -g 999 -c "Valkey|g' \
            -e '/\/usr\/pgsql\//d' \
            "${f}"

        # 验证：sed 后不能还有 postgresql15/18-server
        if grep -qE 'postgresql(15|18)-server' "${f}" 2>/dev/null; then
            warn "    ⚠ sed 未命中，管道兜底: ${f#${src_dir}/}"
            tr -d '\r' < "${f}.bak" | sed \
                -e 's|postgresql18-server|postgresql-server|g' \
                -e 's|postgresql15-server|postgresql-server|g' \
                -e 's|postgresql18-contrib|postgresql-contrib|g' \
                -e 's|postgresql15-contrib|postgresql-contrib|g' \
                -e 's|postgresql18-devel|postgresql-devel|g' \
                -e 's|postgresql15-devel|postgresql-devel|g' \
                -e 's|/usr/pgsql/18/share/postgresql/|/usr/share/postgresql/|g' \
            -e 's|\(/usr/share/postgresql/postgresql.conf.sample\)|\1 \|\| true|g' \
                -e 's|/usr/pgsql/15/share/postgresql/|/usr/share/postgresql/|g' \
            -e 's|\(/usr/share/postgresql/postgresql.conf.sample\)|\1 \|\| true|g' \
                -e 's|tdnf |dnf |g' \
                -e '/\/usr\/pgsql\//d' \
                > "${f}.fix" && mv "${f}.fix" "${f}"
            if grep -qE 'postgresql(15|18)-server' "${f}" 2>/dev/null; then
                warn "    ❌ 仍无法修复，保留备份 ${f}.bak"
                skipped=$((skipped + 1))
                continue
            fi
        fi
        rm -f "${f}.bak"
        fixed=$((fixed + 1))
    done <<< "${all_files}"

    # 终验：不能有残留
    local leftover
    leftover=$(grep -rlE 'postgresql(15|18)-server' "${src_dir}" --include='Dockerfile*' 2>/dev/null || true)
    if [ -n "${leftover}" ]; then
        warn "    ❌ ${skipped}个跳过 ${fixed}个已修复，但以下文件仍有postgresql15/18-server残留:"
        while IFS= read -r f; do [ -n "${f}" ] && warn "      ${f#${src_dir}/}"; done <<< "${leftover}"
        err "Dockerfile 修复失败，无法构建"
    fi
    info "    ✓ ${fixed}个文件已修复${skipped:+, ${skipped}个跳过}"

    # common/Dockerfile: FROM photon → FROM centos
    local cdf="${src_dir}/make/photon/common/Dockerfile"
    if [ -f "${cdf}" ]; then
        if grep -q 'photon:5.0-20260214' "${cdf}" 2>/dev/null; then
            sed -i 's|FROM photon:5.0-20260214|FROM centos:stream9|' "${cdf}"
            info "    ✓ common/Dockerfile: photon → centos"
        fi
        if grep -q 'photon-repos' "${cdf}" 2>/dev/null; then
            sed -i 's|dnf install photon-repos -y|dnf install -y epel-release|' "${cdf}"
        fi
    fi

    # prepare/Dockerfile.base: python3-click（CentOS 需要，Photon 自带）
    # + httpd-tools 替代 rpm2cpio 解包 htpasswd
    local pdf="${src_dir}/make/photon/prepare/Dockerfile.base"
    if [ -f "${pdf}" ]; then
        if grep -q 'python3-jinja2' "${pdf}" 2>/dev/null && ! grep -q 'python3-click' "${pdf}" 2>/dev/null; then
            sed -i 's|python3-jinja2|python3-jinja2 python3-click|' "${pdf}"
            info "    ✓ prepare/Dockerfile.base: +python3-click"
        fi
        if grep -q 'cpio -ivdm.*htpasswd' "${pdf}" 2>/dev/null; then
            sed -i '/rpm cpio apr-util/d' "${pdf}"
            sed -i 's|RUN dnf -y --downloadonly.*htpasswd && rm -f /tmp/\*|RUN dnf --disablerepo=centosplus --disablerepo=PowerTools install -y httpd-tools \&\& dnf clean all|' "${pdf}"
            info "    ✓ prepare/Dockerfile.base: httpd-tools 替代 rpm2cpio"
        fi
    fi

    # log/Dockerfile.base: net-tools（健康检查 netstat -ltun 需要）
    local ldf="${src_dir}/make/photon/log/Dockerfile.base"
    if [ -f "${ldf}" ]; then
        if grep -q 'cronie rsyslog' "${ldf}" 2>/dev/null && ! grep -q 'net-tools' "${ldf}" 2>/dev/null; then
            sed -i 's|cronie rsyslog|cronie rsyslog net-tools|' "${ldf}"
            info "    ✓ log/Dockerfile.base: +net-tools"
        fi
    fi
}

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

command -v unzip &>/dev/null && info "  ✓ unzip" \
    || { dnf install -y unzip 2>/dev/null || { warn "  ✗ unzip"; FAILED=1; }; }

command -v expect &>/dev/null && info "  ✓ expect" \
    || { dnf install -y expect 2>/dev/null || warn "  expect 未安装（git clone 路径需要）"; }

# Go — 优先用预编译二进制，没有则下载官方包
if [ -x "${GO_BIN}" ]; then
    info "  ✓ Go $(${GO_BIN} version 2>&1 | awk '{print $3}') (${GO_DIR})"
    export PATH="${GO_DIR}/bin:${PATH}"
    # 预装 Go 也需配置代理（否则默认 proxy.golang.org 在国内不可达）
    export GOPROXY=https://goproxy.cn,direct
    export GO111MODULE=on
    export GONOSUMCHECK=*
    export GONOSUMDB=*
    export GONOPROXY=
elif command -v go &>/dev/null; then
    go env -w GOPROXY=https://goproxy.cn 2>/dev/null || true
    go env -w GONOSUMCHECK=* GONOSUMDB=* GO111MODULE=on 2>/dev/null || true
    info "  ✓ Go $(go version 2>&1 | awk '{print $3}') (系统)"
else
    warn "  安装 Go..."
    GO_TGZ="go1.26.4.linux-amd64.tar.gz"
    _found=false
    # 优先本地: 脚本目录 → 缓存目录（带完整性校验）
    for d in "${_SCRIPT_DIR}/" "/tmp/build-cache/"; do
        if [ -f "${d}${GO_TGZ}" ] && [ -s "${d}${GO_TGZ}" ]; then
            if tar -tzf "${d}${GO_TGZ}" >/dev/null 2>&1; then
                cp "${d}${GO_TGZ}" /tmp/ && info "  Go 使用本地: ${d}${GO_TGZ}" && _found=true && break
            else
                warn "  Go 本地包损坏，删除: ${d}${GO_TGZ}"; rm -f "${d}${GO_TGZ}"
            fi
        fi
    done
    # 本地没有或损坏则下载（带重试和校验）
    if ! ${_found}; then
        for i in 1 2 3; do
            info "  Go 下载 (${i}/3): https://go.dev/dl/${GO_TGZ}"
            wget -q --show-progress -O "/tmp/${GO_TGZ}" "https://go.dev/dl/${GO_TGZ}" 2>/dev/null || \
                wget -q --show-progress -O "/tmp/${GO_TGZ}" "https://golang.google.cn/dl/${GO_TGZ}" 2>/dev/null || \
                curl -L -o "/tmp/${GO_TGZ}" "https://golang.google.cn/dl/${GO_TGZ}" || true
            if tar -tzf "/tmp/${GO_TGZ}" >/dev/null 2>&1; then
                _found=true; break
            fi
            warn "  Go 下载包校验失败 (${i}/3)"; rm -f "/tmp/${GO_TGZ}"; sleep 5
        done
    fi
    if ${_found}; then
        rm -rf "${GO_DIR}"
        tar -C /usr/local -xzf "/tmp/${GO_TGZ}" && rm -f "/tmp/${GO_TGZ}"
        export PATH="${GO_DIR}/bin:${PATH}"
        go env -w GOPROXY=https://goproxy.cn,direct 2>/dev/null || true
        go env -w GO111MODULE=on 2>/dev/null || true
        go env -w GONOSUMCHECK=* GONOSUMDB=* GONOPROXY= 2>/dev/null || true
        info "  ✓ Go $(go version 2>&1 | awk '{print $3}') (${GO_DIR})"
    else
        warn "  ✗ Go 下载失败"; FAILED=1
    fi
fi

DISK_GB=$(df -BG /opt 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
[ -n "${DISK_GB}" ] && [ "${DISK_GB}" -ge 15 ] \
    && info "  ✓ 磁盘 ${DISK_GB}GB" \
    || { warn "  ✗ 磁盘空间 ${DISK_GB:-?}GB (建议 ≥ 15GB)"; FAILED=1; }

[ $FAILED -eq 1 ] && err "依赖检查未通过，请修复后重试"

# ---- 0-b. 确保基础镜像存在 ----
step "[0-b/9] 检查基础镜像 ${PHOTON_IMAGE}..."
if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${PHOTON_IMAGE}$"; then
    info "  ✓ ${PHOTON_IMAGE} 已存在"
else
    warn "  ${PHOTON_IMAGE} 不存在，自动构建..."
    BASED_SCRIPT="${_SCRIPT_DIR}/build_base.sh"
    if [ -f "${BASED_SCRIPT}" ]; then
        info "  调用: bash ${BASED_SCRIPT}"
        bash "${BASED_SCRIPT}" || err "基础镜像构建失败，请检查 build_base.sh"
    else
        err "未找到 build_base.sh，请先执行: bash build_base.sh"
    fi
fi

# ---- 1. 构建 golang:1.26.4（FROM centos:stream9 + 编译工具 + Go）----
step "[1/9] 构建 golang:1.26.4 (基于 centos:stream9)..."
docker rmi -f golang:1.26.4 2>/dev/null || true

GO_ARCHIVE="go1.26.4.linux-amd64.tar.gz"
_found=false
for d in "${_SCRIPT_DIR}/" "/tmp/build-cache/"; do
    if [ -f "${d}${GO_ARCHIVE}" ] && [ -s "${d}${GO_ARCHIVE}" ]; then
        if tar -tzf "${d}${GO_ARCHIVE}" >/dev/null 2>&1; then
            cp "${d}${GO_ARCHIVE}" /tmp/ && info "  Go 使用本地: ${d}${GO_ARCHIVE}" && _found=true && break
        else
            warn "  Go 本地包损坏，删除: ${d}${GO_ARCHIVE}"; rm -f "${d}${GO_ARCHIVE}"
        fi
    fi
done
if ! ${_found}; then
    for i in 1 2 3; do
        info "  Go 下载 (${i}/3): https://go.dev/dl/${GO_ARCHIVE}"
        wget -q --show-progress -O "/tmp/${GO_ARCHIVE}" "https://go.dev/dl/${GO_ARCHIVE}" 2>/dev/null || \
            wget -q --show-progress -O "/tmp/${GO_ARCHIVE}" "https://golang.google.cn/dl/${GO_ARCHIVE}" 2>/dev/null || \
            curl -L -o "/tmp/${GO_ARCHIVE}" "https://golang.google.cn/dl/${GO_ARCHIVE}" || true
        if tar -tzf "/tmp/${GO_ARCHIVE}" >/dev/null 2>&1; then _found=true; break; fi
        warn "  Go 校验失败 (${i}/3)"; rm -f "/tmp/${GO_ARCHIVE}"; sleep 5
    done
    ${_found} || err "Go 下载失败或包损坏: https://go.dev/dl/${GO_ARCHIVE}"
fi

# 准备构建上下文：centos.repo + dpkg 必须和 Dockerfile 同目录（/tmp）
cp "${_SCRIPT_DIR}/centos.repo" /tmp/centos.repo 2>/dev/null || true
cp "${_SCRIPT_DIR}/dpkg_1.22.22.tar.xz" /tmp/dpkg_1.22.22.tar.xz 2>/dev/null || true

# Dockerfile.golang — FROM centos:stream9 + 编译工具 + dpkg + Go
cat > /tmp/Dockerfile.golang << 'DOCKERFILE_GO'
FROM centos:stream9
COPY centos.repo /etc/yum.repos.d/centos.repo
COPY dpkg_1.22.22.tar.xz /tmp/

RUN dnf install -y epel-release && \
    rm -f /etc/yum.repos.d/epel*.repo && \
    echo '[epel]' > /etc/yum.repos.d/epel.repo && \
    echo 'name=EPEL - Aliyun' >> /etc/yum.repos.d/epel.repo && \
    echo 'baseurl=https://mirrors.aliyun.com/epel/$releasever/Everything/$basearch/' >> /etc/yum.repos.d/epel.repo && \
    echo 'enabled=1' >> /etc/yum.repos.d/epel.repo && \
    echo 'gpgcheck=0' >> /etc/yum.repos.d/epel.repo

RUN dnf install -y --setopt=tsflags=nodocs \
        gcc gcc-c++ make git perl autoconf automake libtool patch \
        gettext-devel glibc-devel kernel-headers \
        openssl-devel libmd-devel ncurses-devel zlib-devel bzip2-devel \
        python3 python3-pip tar xz && \
    dnf clean all && rm -rf /var/cache/dnf

RUN mkdir -p /tmp/dpkg && cd /tmp/dpkg && \
    cp /tmp/dpkg_1.22.22.tar.xz dpkg.tar.xz && \
    tar -xJf dpkg.tar.xz --strip-components=1 && rm -f dpkg.tar.xz && \
    ./configure --disable-nls --prefix=/usr && make -j$(nproc) && make install && \
    cd / && rm -rf /tmp/dpkg /tmp/dpkg_1.22.22.tar.xz && ldconfig && \
    dnf remove -y autoconf automake libtool patch gettext-devel kernel-headers 2>/dev/null || true && \
    dnf clean all && rm -rf /var/cache/dnf /tmp/*

COPY go1.26.4.linux-amd64.tar.gz /tmp/
RUN tar -C /usr/local -xzf /tmp/go1.26.4.linux-amd64.tar.gz && rm /tmp/go1.26.4.linux-amd64.tar.gz

ENV GOROOT=/usr/local/go GOPATH=/go GOPROXY=https://goproxy.cn,direct GO111MODULE=on \
    GONOSUMCHECK=* GONOSUMDB=* GONOPROXY= \
    PATH=/usr/local/go/bin:/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN mkdir -p /go && go version
DOCKERFILE_GO

docker build --progress=plain --no-cache -t golang:1.26.4 -f /tmp/Dockerfile.golang /tmp
rm -f /tmp/Dockerfile.golang "/tmp/${GO_ARCHIVE}"
info "  ✓ golang:1.26.4"

# ---- 2. 构建 node:22.22.3（FROM centos:stream9 + 编译工具 + Node.js）----
step "[2/9] 构建 node:22.22.3 (基于 centos:stream9)..."
docker rmi -f node:22.22.3 2>/dev/null || true

NODE_ARCHIVE="node-v22.22.3-linux-x64.tar.xz"
_found=false
for d in "${_SCRIPT_DIR}/" "/tmp/build-cache/"; do
    if [ -f "${d}${NODE_ARCHIVE}" ] && [ -s "${d}${NODE_ARCHIVE}" ]; then
        if tar -tJf "${d}${NODE_ARCHIVE}" >/dev/null 2>&1; then
            cp "${d}${NODE_ARCHIVE}" /tmp/ && info "  Node 使用本地: ${d}${NODE_ARCHIVE}" && _found=true && break
        else
            warn "  Node 本地包损坏，删除: ${d}${NODE_ARCHIVE}"; rm -f "${d}${NODE_ARCHIVE}"
        fi
    fi
done
if ! ${_found}; then
    for i in 1 2 3; do
        info "  Node 下载 (${i}/3): https://nodejs.org/dist/v22.22.3/${NODE_ARCHIVE}"
        wget -q --show-progress -O "/tmp/${NODE_ARCHIVE}" "https://nodejs.org/dist/v22.22.3/${NODE_ARCHIVE}" 2>/dev/null || \
            wget -q --show-progress -O "/tmp/${NODE_ARCHIVE}" "https://npmmirror.com/mirrors/node/v22.22.3/${NODE_ARCHIVE}" 2>/dev/null || \
            curl -L -o "/tmp/${NODE_ARCHIVE}" "https://npmmirror.com/mirrors/node/v22.22.3/${NODE_ARCHIVE}" || true
        if tar -tJf "/tmp/${NODE_ARCHIVE}" >/dev/null 2>&1; then _found=true; break; fi
        warn "  Node 校验失败 (${i}/3)"; rm -f "/tmp/${NODE_ARCHIVE}"; sleep 5
    done
    ${_found} || err "Node 下载失败或包损坏: https://nodejs.org/dist/v22.22.3/${NODE_ARCHIVE}"
fi

# Dockerfile.node — FROM centos:stream9 + 编译工具 + dpkg + Node.js
cat > /tmp/Dockerfile.node << 'DOCKERFILE_NODE'
FROM centos:stream9
COPY centos.repo /etc/yum.repos.d/centos.repo
COPY dpkg_1.22.22.tar.xz /tmp/

RUN dnf install -y epel-release && \
    rm -f /etc/yum.repos.d/epel*.repo && \
    echo '[epel]' > /etc/yum.repos.d/epel.repo && \
    echo 'name=EPEL - Aliyun' >> /etc/yum.repos.d/epel.repo && \
    echo 'baseurl=https://mirrors.aliyun.com/epel/$releasever/Everything/$basearch/' >> /etc/yum.repos.d/epel.repo && \
    echo 'enabled=1' >> /etc/yum.repos.d/epel.repo && \
    echo 'gpgcheck=0' >> /etc/yum.repos.d/epel.repo

RUN dnf install -y --setopt=tsflags=nodocs \
        gcc gcc-c++ make git perl autoconf automake libtool patch \
        gettext-devel glibc-devel kernel-headers \
        openssl-devel libmd-devel ncurses-devel zlib-devel bzip2-devel \
        python3 python3-pip tar xz && \
    dnf clean all && rm -rf /var/cache/dnf

RUN mkdir -p /tmp/dpkg && cd /tmp/dpkg && \
    cp /tmp/dpkg_1.22.22.tar.xz dpkg.tar.xz && \
    tar -xJf dpkg.tar.xz --strip-components=1 && rm -f dpkg.tar.xz && \
    ./configure --disable-nls --prefix=/usr && make -j$(nproc) && make install && \
    cd / && rm -rf /tmp/dpkg /tmp/dpkg_1.22.22.tar.xz && ldconfig && \
    dnf remove -y autoconf automake libtool patch gettext-devel kernel-headers 2>/dev/null || true && \
    dnf clean all && rm -rf /var/cache/dnf /tmp/*

COPY node-v22.22.3-linux-x64.tar.xz /tmp/
RUN tar -C /usr/local --strip-components=1 -xJf /tmp/node-v22.22.3-linux-x64.tar.xz && rm /tmp/node-v22.22.3-linux-x64.tar.xz

ENV NODE_PATH=/usr/local/lib/node_modules NPM_CONFIG_REGISTRY=https://registry.npmmirror.com \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
RUN node -v && npm -v
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
    # 修复 Windows zip 打包带来的 CRLF 问题（覆盖所有文本/脚本文件）
    # Harbor make/photon/*/builder 无 .sh 后缀也需修复
    find "${BUILD_DIR}" -type f \
        ! -name '*.tar' ! -name '*.gz' ! -name '*.xz' ! -name '*.zip' \
        ! -name '*.png' ! -name '*.ico' ! -name '*.svg' ! -name '*.woff*' \
        ! -name '*.ttf' ! -name '*.eot' ! -name '*.jar' ! -name '*.war' \
        -exec sh -c 'for f; do tr -d "\r" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done' _ {} + 2>/dev/null || true
    chmod -R +x "${BUILD_DIR}/make/" 2>/dev/null || true
    # ── Photon → CentOS: 扫描 + 修复 + 验证 ──
    _apply_photon_fixes "${BUILD_DIR}"
    # 删除损坏的 .git（harbor.zip 中 git 对象文件已损坏，留着影响 Docker build）
    rm -rf "${BUILD_DIR}/.git" 2>/dev/null || true
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

# 修复可能存在的 Windows CRLF 行尾（git clone 也可能带入）
find "${BUILD_DIR}" -type f \
    ! -name '*.tar' ! -name '*.gz' ! -name '*.xz' ! -name '*.zip' \
    ! -name '*.png' ! -name '*.ico' ! -name '*.svg' ! -name '*.woff*' \
    ! -name '*.ttf' ! -name '*.eot' ! -name '*.jar' ! -name '*.war' \
    -exec sh -c 'for f; do tr -d "\r" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done' _ {} + 2>/dev/null || true
chmod -R +x "${BUILD_DIR}/make/" 2>/dev/null || true

_apply_photon_fixes "${BUILD_DIR}"

# ---- 3-b. 预构建 spectral 镜像（解决 GitHub 下载极易中断的问题）----
# 必须在 make compile 之前执行，因为 Harbor 2.11 的 make compile 依赖 lint_apis，
# 而 lint_apis 会触发 Docker build 从 GitHub 下载 spectral（85MB），极易因网络中断失败。
step "[3-b/9] 预构建 spectral 镜像（防止 GitHub 下载中断）..."
if [ -f "${_SCRIPT_DIR}/spectral-linux-x64" ]; then
    info "  使用本地 spectral-linux-x64 构建镜像..."
    cp "${_SCRIPT_DIR}/spectral-linux-x64" /tmp/
    chmod +x /tmp/spectral-linux-x64
    docker build --no-cache -t goharbor/spectral:v6.14.2 -f - /tmp <<'DOCKERFILE_SPECTRAL'
FROM node:22.22.3
COPY spectral-linux-x64 /usr/bin/spectral
RUN chmod +x /usr/bin/spectral && spectral --version
ENTRYPOINT ["/usr/bin/spectral"]
DOCKERFILE_SPECTRAL
    rm -f /tmp/spectral-linux-x64
    info "  ✓ goharbor/spectral:v6.14.2"

    # 替换 Harbor 源码中的 spectral Dockerfile，防止 make lint_apis 二次从 GitHub 下载
    # Harbor 可能有多处 spectral Dockerfile，全部修补为引用预构建镜像
    SPECTRAL_FILES=$(find "${BUILD_DIR}" -path '*/spectral/Dockerfile*' -type f 2>/dev/null || true)
    if [ -n "${SPECTRAL_FILES}" ]; then
        while IFS= read -r sf; do
            [ -n "${sf}" ] || continue
            info "  修补 spectral Dockerfile: ${sf#${BUILD_DIR}/}"
            cat > "${sf}" << 'SPECTRAL_NOOP'
ARG NODE
ARG SPECTRAL_VERSION
FROM goharbor/spectral:v6.14.2
SPECTRAL_NOOP
        done <<< "${SPECTRAL_FILES}"
    else
        warn "  未找到 spectral Dockerfile，lint_apis 可能仍会从 GitHub 下载"
    fi
else
    warn "  本地 spectral-linux-x64 缺失，尝试修补 Dockerfile 添加重试/换源..."
    # 兜底：修补 spectral Dockerfile 添加 wget 重试 + 代理备选
    SPECTRAL_FILES=$(find "${BUILD_DIR}" -path '*/spectral/Dockerfile*' -type f 2>/dev/null || true)
    if [ -n "${SPECTRAL_FILES}" ]; then
        while IFS= read -r sf; do
            [ -n "${sf}" ] || continue
            info "  修补 spectral Dockerfile: ${sf#${BUILD_DIR}/}"
            sed -i 's|curl -fsSL -o /usr/bin/spectral $URL|curl -fsSL --retry 5 --retry-delay 10 --retry-max-time 300 -o /usr/bin/spectral $URL|g' "${sf}"
        done <<< "${SPECTRAL_FILES}"
        warn "  已添加重试，但 GitHub 下载仍可能失败"
    fi
fi

# ---- 4. 编译 Go 二进制 ----
step "[4/9] 编译 Go 二进制..."
go env GOPATH GOPROXY GOROOT 2>/dev/null || true
cd "${BUILD_DIR}"

# make compile 内部已包含 go mod tidy + 代码生成，直接编译即可
make compile VERSIONTAG="v${HARBOR_VER}" GOFLAGS="-mod=mod -buildvcs=false" -j$(nproc) \
    || err "编译失败（检查: 能否访问 goproxy.cn? vendor 目录是否缺失?）"

# ---- 5. 构建镜像 ----
step "[5/9] 构建 Docker 镜像..."

# 禁止 BuildKit 从 Registry 拉取基础镜像，强制使用本地
export BUILDKIT_NO_PULL=1

# （spectral 镜像预构建已提升至步骤[3-b/9]，此处不再重复）

# 强制所有 docker build 加 --pull=false，禁止从 Docker Hub 拉取
find "${BUILD_DIR}" -name 'Makefile' -exec sed -i \
    -e 's|docker build |docker build --pull=false |g' \
    -e 's|--pull=false --pull=false|--pull=false|g' \
    {} \; 2>/dev/null || true
info "  已禁用 docker pull"

# ── 清理上次失败残留（确保修复后的 Dockerfile 被重新构建）──
# 如果基础镜像因上次 postgresql15-server 错误而构建失败，
# Docker 可能保留了半成品镜像 → 删除它们，强制重建
step "[5-b/9] 清理上次失败残留..."
_cleaned=0
for stale in \
    "goharbor/harbor-db-base:v${HARBOR_VER}" \
    "goharbor/harbor-db:v${HARBOR_VER}" \
; do
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${stale}$"; then
        if docker rmi -f "${stale}" 2>/dev/null; then
            info "  已删除: ${stale}"
            _cleaned=$((_cleaned + 1))
        fi
    fi
done
# 清理悬空镜像（中间层 <none>:<none>）
docker image prune -f 2>/dev/null || true
# 清理 BuildKit 缓存（防止引用旧的 Dockerfile 内容哈希）
docker builder prune -f 2>/dev/null || true
[ ${_cleaned} -gt 0 ] && info "  已清理 ${_cleaned} 个旧镜像，将重新构建" || info "  ✓ 无残留"

# 优先本地 tar 加载外部依赖镜像（否则 make build 会尝试拉取）
for tar_img in "valkey-9-alpine.tar" "registry-2.tar" "postgres-15-alpine.tar"; do
    load_local_image "${tar_img}" || true
done

# registry:2 已加载 → 打为 Harbor 标签，跳过 Makefile 中从 GitHub 克隆的 _build_registry
if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^registry:2$'; then
    info "  registry:2 已加载，跳过 _build_registry（避免 GitHub 克隆）"
    docker tag registry:2 "goharbor/harbor-registry:v${HARBOR_VER}"
    # 将 _build_registry 目标改为空操作
    find "${BUILD_DIR}" -name 'Makefile' -exec sed -i \
        's|^_build_registry:.*|_build_registry: ; @true|' {} \; 2>/dev/null || true
fi

# 禁用有问题的 yum 源（阿里云镜像对 centosplus/PowerTools/CRB 经常 404/超时）
# Harbor Dockerfile.base 中 sed -i 's/^enabled.../enabled=1/' 会启用全部源，导致 dnf 超时
# 方案：在 Dockerfile 中 "enable all" 那行之后插入删除问题源文件的命令
info "  禁用有问题的 yum 源（centosplus/PowerTools/CRB）..."
find "${BUILD_DIR}" -name 'Dockerfile*' -type f -exec sed -i \
    -e 's|/etc/yum.repos.d/\*\.repo|/etc/yum.repos.d/*.repo \&\& rm -f /etc/yum.repos.d/*centosplus* /etc/yum.repos.d/*PowerTools* /etc/yum.repos.d/*CRB* /etc/yum.repos.d/*plus* /etc/yum.repos.d/*rt* /etc/yum.repos.d/*nfv* /etc/yum.repos.d/*ha* 2>/dev/null \|\| true|g' \
    {} \;
# 同时给所有 dnf 命令加 --disablerepo 兜底
find "${BUILD_DIR}" -name 'Dockerfile*' -type f -exec sed -i \
    -e 's|dnf makecache|dnf --disablerepo=centosplus --disablerepo=PowerTools makecache|g' \
    -e 's|dnf install |dnf --disablerepo=centosplus --disablerepo=PowerTools install |g' \
    {} \;

# ── 构建前终验：确保不再有 postgresql15/18 ──
# 如果这里仍打印出 postgresql15-server，说明上面的 _apply_photon_fixes 未生效
# 或 make compile 覆盖了文件（极端情况）
step "[5-c/9] 构建前终验..."
_PG_BAD=$(grep -rnE 'postgresql(15|18)-server' "${BUILD_DIR}" --include='Dockerfile*' 2>/dev/null || true)
if [ -n "${_PG_BAD}" ]; then
    warn "  ❌ 构建前发现残留 postgresql15/18-server:"
    echo "${_PG_BAD}" | while IFS= read -r line; do warn "    ${line}"; done
    info "  正在紧急修复..."
    find "${BUILD_DIR}" -name 'Dockerfile*' -type f -exec sed -i \
        -e 's/postgresql18-server/postgresql-server/g' \
        -e 's/postgresql15-server/postgresql-server/g' \
        -e 's/postgresql18-contrib/postgresql-contrib/g' \
        -e 's/postgresql15-contrib/postgresql-contrib/g' \
        -e 's|/usr/pgsql/18/share/postgresql/|/usr/share/postgresql/|g' \
            -e 's|\(/usr/share/postgresql/postgresql.conf.sample\)|\1 \|\| true|g' \
        -e 's|/usr/pgsql/15/share/postgresql/|/usr/share/postgresql/|g' \
            -e 's|\(/usr/share/postgresql/postgresql.conf.sample\)|\1 \|\| true|g' \
            -e '/\/usr\/pgsql\//d' \
        {} \;
    _PG_BAD2=$(grep -rnE 'postgresql(15|18)-server' "${BUILD_DIR}" --include='Dockerfile*' 2>/dev/null || true)
    if [ -n "${_PG_BAD2}" ]; then
        warn "  ❌ 紧急修复后仍有残留:"
        echo "${_PG_BAD2}" | while IFS= read -r line; do warn "    ${line}"; done
        err "无法修复 Dockerfile 中的 postgresql15/18，请手动检查"
    fi
    info "  ✓ 紧急修复完成"
else
    info "  ✓ 无 postgresql15/18-server 残留"
fi

make build VERSIONTAG="v${HARBOR_VER}" \
    BASEIMAGETAG="v${HARBOR_VER}" \
    PULL_BASE_FROM_DOCKERHUB="false" \
    NPM_REGISTRY=https://registry.npmmirror.com \
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
if docker images --format '{{.Tag}}' "goharbor/prepare:v${HARBOR_VER}" 2>/dev/null | grep -q .; then
    info "  安装 htpasswd 到 prepare 镜像..."
    cat > /tmp/htpasswd.py << 'PYEOF'
import sys,hashlib,base64
u,p,f=sys.argv[-2],sys.argv[-1],sys.argv[-3]
h=base64.b64encode(hashlib.sha256(p.encode()).digest()).decode()
open(f,"w").write(u+":"+h+"\n")
PYEOF
    docker rm -f prepare-fix 2>/dev/null || true
    docker run -d --name prepare-fix --entrypoint sleep "goharbor/prepare:v${HARBOR_VER}" 300
    # 轮询等待容器进入 running 状态（sleep 2 不可靠，Docker 启动可能 >2s）
    for i in $(seq 1 30); do
        if docker inspect -f '{{.State.Running}}' prepare-fix 2>/dev/null | grep -q true; then
            break
        fi
        [ $i -eq 30 ] && warn "prepare-fix 容器启动超时，继续尝试..."
        sleep 1
    done
    docker cp /tmp/htpasswd.py prepare-fix:/usr/local/bin/htpasswd
    docker exec prepare-fix chmod 755 /usr/local/bin/htpasswd
    docker exec prepare-fix sed -i 's|/usr/bin/htpasswd|/usr/local/bin/htpasswd|g' /usr/src/app/utils/registry.py
    docker commit prepare-fix "goharbor/prepare:v${HARBOR_VER}"
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
step "[10/10] 完成"
echo ""
echo "============================================"
echo "  Harbor ${HARBOR_VER} 构建完成"
echo "  本地镜像:"
docker images --format '  {{.Repository}}:{{.Tag}}' 2>/dev/null | grep "${HARBOR_VER}" | grep -v goharbor || true
echo ""
echo "  下一步: bash install_harbor.sh ${HARBOR_VER} ${HARBOR_DOMAIN:-harbor.testops.local} ${ADMIN_PASS:-Harbor12345} ${REGISTRY}"
echo "============================================"
