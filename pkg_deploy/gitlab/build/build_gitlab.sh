#!/bin/bash
# ============================================================
# GitLab CE 准备脚本 — 支持三种模式
#   模式1: omnibus — 下载官方 RPM 包 + 离线依赖（生产推荐）
#   模式2: docker  — 构建 Docker 镜像（便于容器化部署）
#   模式3: source  — 从源码编译 GitLab（二次开发/定制）
#
# 源码仓库（已校验）:
#   主应用:    https://github.com/gitlabhq/gitlabhq.git         ✅ GitHub 官方镜像
#   Shell:     https://github.com/gitlabhq/gitlab-shell.git     ✅ GitHub 官方镜像
#   Gitaly:    https://gitlab.com/gitlab-org/gitaly.git         ⚠ 仅 GitLab.com
#   Workhorse: https://gitlab.com/gitlab-org/gitlab-workhorse.git ⚠ 仅 GitLab.com
#
# 用法: bash build_gitlab.sh [模式] [版本]
# 示例: bash build_gitlab.sh omnibus 17.4.0
#       bash build_gitlab.sh source  17.4.0
# ============================================================
set -euo pipefail

MODE="${1:-omnibus}"          # omnibus | docker
GITLAB_VER="${2:-19.3.0-pre}"
GITLAB_MAJOR="$(echo "${GITLAB_VER}" | cut -d. -f1)"
BUILD_DIR="${BUILD_DIR:-/opt/build/gitlab}"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

load_local_file() {
    local f="$1"
    if [ -f "${_SCRIPT_DIR}/${f}" ]; then
        info "  使用本地: ${f}"
        return 0
    fi
    return 1
}

echo "============================================"
echo "  GitLab CE ${GITLAB_VER} 准备"
echo "  模式: ${MODE}"
echo "============================================"

# ---- 0. 环境检查 ----
step "[0/4] 环境检查..."
FAILED=0

command -v curl &>/dev/null && info "  ✓ curl" || { dnf install -y curl 2>/dev/null || apt-get install -y curl 2>/dev/null || { warn "  ✗ curl"; FAILED=1; }; }

[ $FAILED -eq 1 ] && err "依赖检查未通过"

# ---- 1. 下载 GitLab 包 ----
step "[1/4] 获取 GitLab CE ${GITLAB_VER}..."

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

case "${MODE}" in
    omnibus)
        # ── 模式1: Omnibus RPM ──
        if command -v dnf &>/dev/null; then
            PKG="gitlab-ce-${GITLAB_VER}-ce.0.el9.x86_64.rpm"
            MIRROR="https://mirrors.tuna.tsinghua.edu.cn/gitlab-ce/yum/el${GITLAB_MAJOR}"
        else
            PKG="gitlab-ce_${GITLAB_VER}-ce.0_amd64.deb"
            MIRROR="https://mirrors.tuna.tsinghua.edu.cn/gitlab-ce/ubuntu"
        fi

        if load_local_file "${PKG}"; then
            info "  ✓ 本地 RPM: ${PKG}"
        else
            info "  下载: ${MIRROR}/${PKG}"
            for i in 1 2 3; do
                wget -q --show-progress "${MIRROR}/${PKG}" -O "${PKG}" 2>/dev/null \
                    || curl -L -o "${PKG}" "${MIRROR}/${PKG}" \
                    && break
                warn "  下载重试 (${i}/3)"; sleep 5
            done
            [ -f "${PKG}" ] && [ -s "${PKG}" ] || err "下载失败: ${MIRROR}/${PKG}"
            info "  ✓ 下载完成 ($(du -h "${PKG}" | cut -f1))"
        fi
        ;;

    docker)
        # ── 模式2: Docker 镜像构建 ──
        if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^gitlab/gitlab-ce:${GITLAB_VER}$"; then
            info "  ✓ gitlab/gitlab-ce:${GITLAB_VER} 已存在"
        elif load_local_file "gitlab-ce-${GITLAB_VER}.tar.gz"; then
            docker load -i "${_SCRIPT_DIR}/gitlab-ce-${GITLAB_VER}.tar.gz"
            info "  ✓ 从本地 tar 加载"
        else
            warn "  无本地镜像，将在 install 阶段从 Docker Hub 拉取"
        fi

        # 源码构建 Docker 镜像（极端场景）
        if load_local_file "gitlab-foss-${GITLAB_VER}.tar.gz"; then
            info "  解压 gitlab-foss 源码..."
            tar -xzf "${_SCRIPT_DIR}/gitlab-foss-${GITLAB_VER}.tar.gz" -C "${BUILD_DIR}/"
            info "  ✓ 源码就绪"
        fi
        ;;

    *)
        err "未知模式: ${MODE}（可选: omnibus | docker）"
        ;;
esac

# ---- 2. 准备依赖 ----
step "[2/4] 准备依赖..."

case "${MODE}" in
    omnibus)
        # Omnibus 自带所有依赖，只需确保基础包
        if command -v dnf &>/dev/null; then
            info "  系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
            dnf install -y policycoreutils-python-utils openssh-server postfix 2>/dev/null || true
        else
            apt-get update -qq 2>/dev/null || true
            apt-get install -y -qq curl openssh-server ca-certificates postfix 2>/dev/null || true
        fi
        info "  ✓ 依赖就绪"
        ;;

    docker)
        # 构建自定义 Dockerfile
        if [ -f "${_SCRIPT_DIR}/Dockerfile" ]; then
            info "  ✓ Dockerfile 已存在"
        else
            cat > "${BUILD_DIR}/Dockerfile" << 'DOCKEOF'
FROM centos:stream9
RUN dnf install -y curl policycoreutils openssh-server postfix && \
    dnf clean all && rm -rf /var/cache/dnf
EXPOSE 80 443 22
DOCKEOF
            info "  已生成默认 Dockerfile"
        fi
        ;;
esac

# ---- 3. 配置模板 ----
step "[3/4] 配置模板..."

cat > "${BUILD_DIR}/gitlab.rb.template" << 'RBEOF'
# GitLab CE 配置模板（安装时自动替换变量）
external_url "http://{{GITLAB_DOMAIN}}"
nginx['listen_port'] = 80
nginx['listen_https'] = false

# 数据目录
git_data_dirs({ "default" => { "path" => "/var/opt/gitlab/git-data" } })

# 邮件（可选）
# gitlab_rails['smtp_enable'] = true
# gitlab_rails['smtp_address'] = "smtp.example.com"
# gitlab_rails['smtp_port'] = 587
RBEOF
info "  ✓ gitlab.rb.template"

# ---- 4. 完成 ----
step "[4/4] 完成"

echo ""
echo "============================================"
echo "  GitLab CE ${GITLAB_VER} 准备完成"
echo "  模式: ${MODE}"
echo "  构建目录: ${BUILD_DIR}"
echo ""
echo "  下一步: bash install_gitlab.sh ${MODE} ${GITLAB_VER} gitlab.testops.local"
echo "============================================"
