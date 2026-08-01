#!/bin/bash
# ============================================================
# GitLab CE 安装启动 — 支持两种模式
#   模式1: omnibus — RPM 安装 → gitlab-ctl reconfigure → 启动
#   模式2: docker  — docker run 容器化部署
#
# 用法: bash install_gitlab.sh [模式] [版本] [域名/IP] [--port 80]
# ============================================================
set -euo pipefail

MODE="${1:-omnibus}"
GITLAB_VER="${2:-19.3.0-pre}"
GITLAB_DOMAIN="${3:-gitlab.testops.local}"
GITLAB_PORT="${GITLAB_PORT:-80}"
BUILD_DIR="${BUILD_DIR:-/opt/build/gitlab}"
INSTALL_DIR="${INSTALL_DIR:-/opt/gitlab}"
DATA_DIR="${DATA_DIR:-/data/gitlab}"
FORCE=false
ROOT_PASS="${GITLAB_ROOT_PASSWORD:-Gitlab12345}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --port)  GITLAB_PORT="$2"; shift 2 ;;
        --pass)  ROOT_PASS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

[ "$(id -u)" -eq 0 ] || err "需要 root 权限"

echo "============================================"
echo "  GitLab CE ${GITLAB_VER} 安装启动"
echo "  模式: ${MODE}"
echo "  域名: ${GITLAB_DOMAIN}"
echo "============================================"

# ---- 0. 环境检查 ----
step "[0/6] 环境检查..."

# 内存检查（GitLab 最低 4GB）
MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
[ "${MEM_MB}" -ge 3800 ] && info "  内存 ${MEM_MB}MB" || warn "  内存 ${MEM_MB}MB（GitLab 建议 >= 4GB）"

case "${MODE}" in
    omnibus)
        if gitlab-ctl status &>/dev/null; then
            ${FORCE} || { info "GitLab 已运行"; exit 0; }
            warn "--force: 覆盖已有安装"
            gitlab-ctl stop 2>/dev/null || true
        fi
        ;;

    docker)
        command -v docker &>/dev/null && info "  Docker" || err "Docker 未安装"
        systemctl is-active docker &>/dev/null || { systemctl start docker; systemctl enable docker; }
        ;;
esac

# ---- 1. 磁盘 ----
step "[1/6] 磁盘准备..."
mkdir -p "${INSTALL_DIR}" "${DATA_DIR}"

DISK_GB=$(df -BG "${DATA_DIR}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
[ -n "${DISK_GB}" ] && [ "${DISK_GB}" -ge 20 ] \
    && info "  磁盘 ${DISK_GB}GB" \
    || warn "  磁盘空间 ${DISK_GB:-?}GB（建议 >= 20GB）"

case "${MODE}" in
    omnibus)
        # ── 模式1: Omnibus RPM 安装 ──
        step "[2/6] 安装 RPM..."
        GITLAB_PKG=$(find "${BUILD_DIR}" -name "gitlab-ce-${GITLAB_VER}*.rpm" -type f 2>/dev/null | head -1)
        [ -n "${GITLAB_PKG}" ] || err "RPM 包不存在: ${BUILD_DIR}/gitlab-ce-${GITLAB_VER}*.rpm"
        info "  安装: $(basename ${GITLAB_PKG}) ($(du -h ${GITLAB_PKG} | cut -f1))"

        # 安装
        if command -v dnf &>/dev/null; then
            dnf install -y "${GITLAB_PKG}"
        else
            dpkg -i "${GITLAB_PKG}"
        fi
        info "  ✓ RPM 已安装"

        # 配置 gitlab.rb
        step "[3/6] 配置 gitlab.rb..."
        sed -i "s|^external_url.*|external_url 'http://${GITLAB_DOMAIN}'|" /etc/gitlab/gitlab.rb
        sed -i "s|^# nginx\['listen_port'\].*|nginx['listen_port'] = ${GITLAB_PORT}|" /etc/gitlab/gitlab.rb
        echo "gitlab_rails['initial_root_password'] = '${ROOT_PASS}'" >> /etc/gitlab/gitlab.rb
        info "  ✓ gitlab.rb 已配置"

        # Recon figure
        step "[4/6] gitlab-ctl reconfigure（首次需要 5-10 分钟）..."
        gitlab-ctl reconfigure 2>&1 || warn "reconfigure 有警告"
        info "  ✓ reconfigure 完成"

        # 启动
        step "[5/6] 启动 GitLab..."
        gitlab-ctl start
        info "  等待 GitLab 就绪..."

        for i in $(seq 1 60); do
            if curl -sk --connect-timeout 3 "http://127.0.0.1:${GITLAB_PORT}/help" 2>/dev/null | grep -q 'GitLab'; then
                info "GitLab 就绪 (${i}/60)"; break
            fi
            [ $i -eq 60 ] && warn "超时，检查: gitlab-ctl status" || sleep 5
        done
        ;;

    docker)
        # ── 模式2: Docker 部署 ──
        step "[2/6] 拉取镜像..."
        GITLAB_IMAGE="gitlab/gitlab-ce:${GITLAB_VER}"

        if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${GITLAB_IMAGE}$"; then
            if [ -f "${_SCRIPT_DIR}/gitlab-ce-${GITLAB_VER}.tar.gz" ]; then
                docker load -i "${_SCRIPT_DIR}/gitlab-ce-${GITLAB_VER}.tar.gz"
                info "  从本地 tar 加载"
            else
                docker pull "${GITLAB_IMAGE}" 2>&1 || warn "拉取失败，尝试国内镜像"
                docker pull "registry.cn-hangzhou.aliyuncs.com/ethanx/gitlab-ce:${GITLAB_VER}" 2>/dev/null \
                    && docker tag "registry.cn-hangzhou.aliyuncs.com/ethanx/gitlab-ce:${GITLAB_VER}" "${GITLAB_IMAGE}"
            fi
        fi
        info "  ✓ ${GITLAB_IMAGE}"

        # 启动容器
        step "[3/6] 启动容器..."
        docker rm -f gitlab 2>/dev/null || true

        docker run -d --name gitlab \
            --restart always \
            --hostname "${GITLAB_DOMAIN}" \
            -p "${GITLAB_PORT}:${GITLAB_PORT}" \
            -p 2222:22 \
            -v "${DATA_DIR}/config:/etc/gitlab" \
            -v "${DATA_DIR}/logs:/var/log/gitlab" \
            -v "${DATA_DIR}/data:/var/opt/gitlab" \
            -e GITLAB_OMNIBUS_CONFIG="external_url 'http://${GITLAB_DOMAIN}:${GITLAB_PORT}'; gitlab_rails['initial_root_password']='${ROOT_PASS}';" \
            "${GITLAB_IMAGE}"         info "  ✓ 容器已启动"

        step "[4/6] 等待 GitLab 就绪（首次 3-5 分钟）..."
        for i in $(seq 1 60); do
            if curl -sk --connect-timeout 3 "http://127.0.0.1:${GITLAB_PORT}/help" 2>/dev/null | grep -q 'GitLab'; then
                info "GitLab 就绪 (${i}/60)"; break
            fi
            [ $i -eq 60 ] && warn "超时，检查: docker logs gitlab" || sleep 5
        done
        ;;

    *)
        err "未知模式: ${MODE}"
        ;;
esac

# ---- 6. 验证 ----
step "[6/6] 验证..."

info "  访问:  http://${GITLAB_DOMAIN}:${GITLAB_PORT}"
info "  账号:  root"
info "  密码:  ${ROOT_PASS}"

case "${MODE}" in
    omnibus)
        info "  管理:  gitlab-ctl [start|stop|restart|status]"
        info "  卸载:  bash clean_gitlab.sh omnibus"
        ;;
    docker)
        info "  管理:  docker [start|stop|restart] gitlab"
        info "  卸载:  bash clean_gitlab.sh docker"
        ;;
esac

echo ""
echo "============================================"
echo "  GitLab CE ${GITLAB_VER} 安装完成"
echo "============================================"
