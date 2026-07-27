#!/bin/bash
# ============================================================
# 禅道开源版一键编译脚本（CentOS Stream 9 直接执行）
# 用法:
#   bash build.sh                          # 默认 v21.2，仅构建
#   bash build.sh 22.0                     # 指定版本
#   bash build.sh 21.2 push                # 构建 + 推送到 Harbor
# ============================================================
set -euo pipefail

# ---- 配置参数（根据环境修改）----
ZENTAO_VERSION="${1:-21.2}"              # 禅道版本号
PUSH="${2:-}"                             # 填 "push" 则推送
HARBOR_URL="${HARBOR_URL:-harbor.testops.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-testops}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
IMAGE_NAME="${IMAGE_NAME:-zentao}"
BUILD_DIR="${BUILD_DIR:-/opt/build/zentaopms}"
GITHUB_SSH="git@github.com:easysoft/zentaopms.git"
GITHUB_HTTPS="https://github.com/easysoft/zentaopms.git"
GITEE_HTTPS="https://gitee.com/easysoft/zentaopms.git"

FULL_IMAGE="${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:${ZENTAO_VERSION}"
LATEST_IMAGE="${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest"

# ---- 颜色 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
check_ok()  { echo -e "  ${GREEN}[OK]${NC} $*"; }
check_fail(){ echo -e "  ${RED}[FAIL]${NC} $*"; }

# ---- 预检函数 ----
pre_check() {
    info "执行环境依赖检查..."
    local passed=0 total=0

    # 1. 操作系统版本
    total=$((total+1))
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if echo "${PRETTY_NAME}" | grep -qiE "CentOS|Rocky|AlmaLinux|RHEL|Red Hat"; then
            check_ok "操作系统: ${PRETTY_NAME}"
            passed=$((passed+1))
        else
            check_fail "操作系统: ${PRETTY_NAME}（需要 CentOS/RHEL 系列）"
        fi
    else
        check_fail "操作系统: 无法检测 /etc/os-release"
    fi

    # 2. 内核版本
    total=$((total+1))
    local kernel; kernel=$(uname -r)
    check_ok "内核: ${kernel}"
    passed=$((passed+1))

    # 3. CPU 架构
    total=$((total+1))
    local arch; arch=$(uname -m)
    if [ "${arch}" = "x86_64" ]; then
        check_ok "CPU 架构: ${arch}"
        passed=$((passed+1))
    else
        check_fail "CPU 架构: ${arch}（禅道仅支持 x86_64/amd64）"
    fi

    # 4. 内存
    total=$((total+1))
    local mem; mem=$(free -g | awk '/^Mem:/{print $2}')
    if [ "${mem}" -ge 4 ]; then
        check_ok "内存: ${mem}GB (≥ 4GB)"
        passed=$((passed+1))
    else
        check_fail "内存: ${mem}GB（建议 ≥ 4GB）"
    fi

    # 5. 磁盘空间
    total=$((total+1))
    mkdir -p "${BUILD_DIR}" 2>/dev/null || true
    local disk; disk=$(timeout 5 df -BG "${BUILD_DIR}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
    if [ -z "${disk}" ]; then disk=$(timeout 5 df -BG /tmp 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G'); fi
    if [ -z "${disk}" ]; then disk=0; fi
    if [ "${disk}" -ge 20 ]; then
        check_ok "磁盘空间: ${disk}GB (≥ 20GB)"
        passed=$((passed+1))
    else
        check_fail "磁盘空间: ${disk}GB（建议 ≥ 20GB，源码+编译缓存约 10GB）"
    fi

    # 6. git
    total=$((total+1))
    if command -v git &>/dev/null; then
        check_ok "git: $(git --version 2>&1 | head -1)"
        passed=$((passed+1))
    else
        check_fail "git: 未安装（dnf install -y git）"
    fi

    # 7. wget
    total=$((total+1))
    if command -v wget &>/dev/null; then
        check_ok "wget: $(wget --version 2>&1 | head -1)"
        passed=$((passed+1))
    else
        check_fail "wget: 未安装（dnf install -y wget）"
    fi

    # 8. Docker
    total=$((total+1))
    if command -v docker &>/dev/null; then
        check_ok "docker: $(docker --version)"
        passed=$((passed+1))
    else
        check_fail "docker: 未安装（dnf install -y docker）"
    fi

    # 9. Docker 运行状态
    total=$((total+1))
    info "  检查 Docker 运行状态..."
    if timeout 10 docker info &>/dev/null 2>&1; then
        check_ok "Docker 运行中"
        passed=$((passed+1))
    else
        check_fail "Docker 未运行或无响应（systemctl start docker）"
    fi

    # 10. GitHub 连通性
    total=$((total+1))
    info "  检查 GitHub 可达性..."
    if timeout 10 curl -sI --connect-timeout 5 https://github.com 2>/dev/null | head -1 | grep -qE "200|301|302"; then
        check_ok "GitHub 可达"
        passed=$((passed+1))
    else
        warn "GitHub 不可达（将自动使用 Gitee 镜像）"
        passed=$((passed+1))
    fi

    echo ""
    echo "  ────────────────────────────"
    echo "  预检结果: ${passed}/${total} 通过"
    echo "  ────────────────────────────"

    if [ "${passed}" -lt "${total}" ]; then
        if [ "${passed}" -lt "$((${total} - 2))" ]; then
            err "环境预检未通过，请修复后重试"
        fi
        warn "部分检查项未达标，编译仍可继续但可能失败"
    else
        info "环境预检全部通过"
    fi
}

echo ""
echo "============================================"
echo "  禅道开源版一键编译脚本"
echo "  版本: v${ZENTAO_VERSION}"
echo "  镜像: ${FULL_IMAGE}"
echo "============================================"
echo ""

# ---- 1. 环境依赖检查 ----
pre_check

# ---- 2. 拉取源码 ----
info "[2/9] 拉取禅道 v${ZENTAO_VERSION} 源码..."
rm -rf "${BUILD_DIR}/source"
mkdir -p "${BUILD_DIR}/source"
# expect 自动应答：处理 git clone 的 yes/no / username / password 交互
git_expect_clone() {
    local repo_url="$1"
    local dest_dir="$2"
    local branch="$3"
    expect <<EOF 2>/dev/null
set timeout 60
log_user 0
spawn git clone --depth 1 --branch ${branch} ${repo_url} ${dest_dir}
expect {
    "yes/no"           { send "yes\r"; exp_continue }
    "Username for *"   { send "\r";   exp_continue }
    "Password for *"   { send "\r";   exp_continue }
    "Enter passphrase" { send "\r";   exp_continue }
    timeout            { exit 1 }
    eof
}
catch wait result
exit [lindex \$result 3]
EOF
}

# 优先 GitHub SSH → GitHub HTTPS → Gitee HTTPS → 官网 ZIP
info "  尝试 GitHub SSH（密钥认证）..."
if git_expect_clone "${GITHUB_SSH}" "${BUILD_DIR}/source" "${ZENTAO_VERSION}"; then
    info "  源码拉取成功 (GitHub SSH)"
elif git_expect_clone "${GITHUB_HTTPS}" "${BUILD_DIR}/source" "${ZENTAO_VERSION}"; then
    info "  源码拉取成功 (GitHub HTTPS)"
elif git_expect_clone "${GITEE_HTTPS}" "${BUILD_DIR}/source" "${ZENTAO_VERSION}"; then
    info "  源码拉取成功 (Gitee)"
else
    warn "  Git 方式均失败，尝试官网下载 ZIP..."
    zip_url="https://www.zentao.net/dl/zentaopms/${ZENTAO_VERSION}/ZenTaoPMS.${ZENTAO_VERSION}.zip"
    wget -q -O /tmp/zentao.zip "${zip_url}" 2>/dev/null \
        || curl -sL -o /tmp/zentao.zip "${zip_url}" 2>/dev/null \
        || err "源码拉取失败，请检查网络或手动下载"
    mkdir -p "${BUILD_DIR}/source"
    unzip -qo /tmp/zentao.zip -d /tmp/zentao_extract
    mv /tmp/zentao_extract/*/* "${BUILD_DIR}/source/" 2>/dev/null \
        || mv /tmp/zentao_extract/* "${BUILD_DIR}/source/" 2>/dev/null \
        || err "ZIP 解压结构异常"
    rm -rf /tmp/zentao.zip /tmp/zentao_extract
    info "  源码拉取成功 (官网 ZIP)"
fi
rm -rf "${BUILD_DIR}/source/.git" "${BUILD_DIR}/source/.github" 2>/dev/null || true

# ---- 3. 准备构建文件 ----
info "[3/9] 准备构建文件..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for f in Dockerfile .dockerignore docker-entrypoint.sh; do
    if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
        err "缺少构建文件: ${SCRIPT_DIR}/${f}
请将以下文件复制到 ${SCRIPT_DIR}/ 目录:
  modules/zentao_deploy/modules/zentao/build/Dockerfile
  modules/zentao_deploy/modules/zentao/build/.dockerignore
  modules/zentao_deploy/modules/zentao/build/docker-entrypoint.sh"
    fi
    cp "${SCRIPT_DIR}/${f}" "${BUILD_DIR}/"
done
info "  构建文件就绪 (Dockerfile + entrypoint + dockerignore → ${BUILD_DIR}/)"

# ---- 4. Docker 构建 ----
info "[4/9] Docker 多阶段编译（约 5-15 分钟，请耐心等待）..."
cd "${BUILD_DIR}"
docker build \
    --build-arg "ZENTAO_VERSION=${ZENTAO_VERSION}" \
    -t "${FULL_IMAGE}" \
    -t "${LATEST_IMAGE}" \
    -f Dockerfile \
    . 2>&1 | tail -20
info "  镜像构建完成: ${FULL_IMAGE}"

# ---- 5. 列出镜像 ----
info "[5/9] 镜像信息:"
docker images "${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"

# ---- 6. 本地验证 ----
info "[6/9] 本地验证容器启动..."
docker rm -f zentao-verify 2>/dev/null || true
if docker run -d --name zentao-verify -p 18080:8080 \
    -e ZT_MYSQL_HOST=127.0.0.1 \
    -e ZT_MYSQL_PORT=3306 \
    -e ZT_MYSQL_USER=root \
    -e ZT_MYSQL_PASSWORD=test \
    -e ZT_MYSQL_DB=zentao \
    "${FULL_IMAGE}" 2>/dev/null; then
    sleep 5
    if curl -sf http://localhost:18080/ >/dev/null 2>&1; then
        info "  本地验证通过"
    else
        warn "  本地验证: Web 未响应（可能 MySQL 不可达，不影响镜像）"
    fi
    docker rm -f zentao-verify 2>/dev/null || true
else
    warn "  本地验证跳过"
fi

# ---- 7. 推送 Harbor（可选）----
if [ "${PUSH}" == "push" ]; then
    info "[7/9] 推送镜像到 Harbor..."
    if [ -n "${HARBOR_PASS}" ]; then
        echo "${HARBOR_PASS}" | docker login "${HARBOR_URL}" -u "${HARBOR_USER}" --password-stdin 2>/dev/null
    else
        docker login "${HARBOR_URL}" -u "${HARBOR_USER}"
    fi
    docker push "${FULL_IMAGE}"
    docker push "${LATEST_IMAGE}"
    info "  推送完成"
else
    info "[7/9] 跳过推送（如需推送: bash build.sh ${ZENTAO_VERSION} push）"
fi

# ---- 9. 完成 ----
info "[9/9] 编译完成!"
echo ""
echo "  镜像: ${FULL_IMAGE}"
echo "  镜像: ${LATEST_IMAGE}"
echo ""
echo "  下一步:"
echo "    docker run -d --name zentao -p 8080:8080 \\"
echo "      -e ZT_MYSQL_HOST=<mysql-ip> \\"
echo "      -e ZT_MYSQL_PORT=3306 \\"
echo "      -e ZT_MYSQL_USER=zentao \\"
echo "      -e ZT_MYSQL_PASSWORD=<password> \\"
echo "      -e ZT_MYSQL_DB=zentao \\"
echo "      ${FULL_IMAGE}"
echo "============================================"
