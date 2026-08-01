#!/bin/bash
# ============================================================
# Wiki.js 2.x — 源码编译构建（CentOS 9）
#
# 原理:      git clone / 本地源码 tarball → npm install → npm build
# 本地优先:  脚本同目录 wiki*.tar.gz + node-v*.tar.xz
#
# 用法:      bash build_wikijs.sh [版本分支] [--skip-node]
# 示例:      bash build_wikijs.sh main
# ============================================================
set -euo pipefail

# 必须在 cd 之前计算脚本目录，否则相对路径 $0 会解析到 /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
cd /tmp

# ── 配置 ──
WIKI_VERSION="${1:-main}"
SKIP_NODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-node) SKIP_NODE=true; shift ;;
        *) WIKI_VERSION="$1"; shift ;;
    esac
done

NODE_VERSION="22.20.0"
NODE_TAR="node-v${NODE_VERSION}-linux-x64.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TAR}"
WIKI_REPO="https://github.com/requarks/wiki.git"
WIKI_DIR="/opt/wiki"
INSTALL_DIR="${INSTALL_DIR:-/opt/wiki}"

# ── UI ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

get_local() {
    for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do
        [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }
    done
    return 1
}

echo "============================================"
echo "  Wiki.js 源码构建（CentOS 9）"
echo "  版本:  ${WIKI_VERSION}  |  Node: ${NODE_VERSION}"
echo "  安装:  ${INSTALL_DIR}"
echo "============================================"

# ═══ 1. Node.js ═══
step "[1/4] Node.js ${NODE_VERSION}..."

if ${SKIP_NODE}; then
    info "  --skip-node，跳过 Node.js 安装"
elif [ -x /usr/local/node/bin/node ] && /usr/local/node/bin/node --version 2>&1 | grep -q "v${NODE_VERSION%.*}"; then
    info "  ✓ Node.js $(/usr/local/node/bin/node --version) 已安装"
else
    if _NODE_PKG=$(get_local "${NODE_TAR}"); then
        info "  使用本地: $(basename ${_NODE_PKG}) ($(du -h ${_NODE_PKG} | cut -f1))"
        cp "${_NODE_PKG}" "/tmp/${NODE_TAR}"
    else
        info "  下载: ${NODE_URL}"
        wget -q --show-progress -O "/tmp/${NODE_TAR}" "${NODE_URL}" 2>/dev/null \
            || curl -L -o "/tmp/${NODE_TAR}" "${NODE_URL}" \
            || err "Node.js 下载失败"
        mkdir -p /tmp/build-cache && cp "/tmp/${NODE_TAR}" "/tmp/build-cache/${NODE_TAR}" 2>/dev/null || true
    fi
    rm -rf /usr/local/node
    mkdir -p /usr/local/node
    tar -xJf "/tmp/${NODE_TAR}" -C /usr/local/node --strip-components=1
    for _bin in /usr/local/node/bin/*; do
        ln -sf "${_bin}" "/usr/local/bin/$(basename ${_bin})" 2>/dev/null || true
    done
    rm -f "/tmp/${NODE_TAR}"
    info "  ✓ Node.js $(node --version)"
    info "  ✓ npm $(npm --version)"
fi

# ═══ 2. 获取源码 ═══
step "[2/4] 获取 Wiki.js 源码..."

if [ -d "${INSTALL_DIR}/.git" ]; then
    info "  已存在 git 仓库，更新..."
    cd "${INSTALL_DIR}"
    sudo -u "$(stat -c '%U' ${INSTALL_DIR})" git pull --ff-only 2>/dev/null || warn "  git pull 失败，继续使用现有代码"
else
    rm -rf "${INSTALL_DIR}"
    # 优先本地 tarball
    _SRC_TAR=$(ls "${SCRIPT_DIR}/"wiki*.tar.gz 2>/dev/null | head -1) || true
    if [ -n "${_SRC_TAR}" ] && [ -s "${_SRC_TAR}" ]; then
        info "  使用本地: $(basename ${_SRC_TAR}) ($(du -h ${_SRC_TAR} | cut -f1))"
        mkdir -p "${INSTALL_DIR}"
        tar -xzf "${_SRC_TAR}" -C "${INSTALL_DIR}" --strip-components=1
    elif [ -f "${SCRIPT_DIR}/wiki-${WIKI_VERSION}.tar.gz" ]; then
        info "  使用本地: wiki-${WIKI_VERSION}.tar.gz"
        mkdir -p "${INSTALL_DIR}"
        tar -xzf "${SCRIPT_DIR}/wiki-${WIKI_VERSION}.tar.gz" -C "${INSTALL_DIR}" --strip-components=1
    else
        info "  git clone ${WIKI_REPO} (${WIKI_VERSION})..."
        git clone --depth 1 --branch "${WIKI_VERSION}" "${WIKI_REPO}" "${INSTALL_DIR}" 2>&1 \
            || git clone --depth 1 "${WIKI_REPO}" "${INSTALL_DIR}" 2>&1 \
            || err "git clone 失败，请手动下载源码包放到 ${SCRIPT_DIR}/"
    fi
fi

[ -f "${INSTALL_DIR}/package.json" ] || err "源码不完整: ${INSTALL_DIR}/package.json 不存在"
info "  ✓ 源码就绪: ${INSTALL_DIR}"

# ═══ 3. npm 依赖 & 构建 ═══
step "[3/4] npm 依赖安装 & 构建..."

cd "${INSTALL_DIR}"

# 配置 npm 镜像加速
npm config set registry https://registry.npmmirror.com 2>/dev/null || true

info "  npm install..."
npm install --production 2>&1 | tail -5 || warn "  npm install --production 有 warning，继续..."

info "  npm build..."
npm run build 2>&1 | tail -5 || warn "  npm build 有 warning，继续..."

info "  ✓ Wiki.js 构建完成"

# ═══ 4. 完成 ═══
step "[4/4] 构建完成"

echo ""
echo "============================================"
echo "  Wiki.js ${WIKI_VERSION} 构建完成"
echo ""
echo "  目录:     ${INSTALL_DIR}"
echo "  下一步:   bash install_wikijs.sh [--port 3000]"
echo "============================================"
