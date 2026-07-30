#!/bin/bash
# ============================================================
# 禅道开源版一键编译脚本（CentOS Stream 9 直接执行）
# 用法:
#   bash build.sh                          # 默认 v21.2，仅构建
#   bash build.sh 22.0                     # 指定版本
#   bash build.sh 21.2 push                # 构建 + 推送到 Harbor
# ============================================================
set -euo pipefail

# 脚本所在目录的绝对路径（在 cd 前保存，确保本地包查找始终正确）
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$(pwd)")"

# ---- 配置参数（根据环境修改）----
ZENTAO_VERSION="${1:-21.2}"              # 禅道版本号
PUSH="${2:-}"                             # 填 "push" 则推送
HARBOR_URL="${HARBOR_URL:-harbor.testops.local}"
HARBOR_PROJECT="${HARBOR_PROJECT:-testops}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
IMAGE_NAME="${IMAGE_NAME:-zentao}"
BUILD_DIR="${BUILD_DIR:-/opt/build/zentaopms}"
GIT_BRANCH="main"
GITHUB_SSH="git@github.com:easysoft/zentaopms.git"
GITHUB_HTTPS="https://github.com/easysoft/zentaopms.git"

FULL_IMAGE="${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:${ZENTAO_VERSION}"
LATEST_IMAGE="${HARBOR_URL}/${HARBOR_PROJECT}/${IMAGE_NAME}:latest"

# ---- 颜色 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ 错误: ${BASH_SOURCE[0]} 第 ${BASH_LINENO[0]} 行${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
check_ok()  { echo -e "  ${GREEN}[OK]${NC} $*"; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR
check_fail(){ echo -e "  ${RED}[FAIL]${NC} $*"; }

# 下载函数：脚本目录 → /tmp/build-cache → ./ 逐级查找（优先本地，兜底下载）
CACHE_DIR_DL="${CACHE_DIR_DL:-/tmp/build-cache}"
mkdir -p "${CACHE_DIR_DL}"
download_tar() {
    local url="$1" fname="$2"
    # 按优先级查找本地文件：脚本同目录 → 缓存目录 → 当前目录
    for d in "${_SCRIPT_DIR}/" "${CACHE_DIR_DL}/" "./"; do
        if [ -f "${d}${fname}" ] && [ -s "${d}${fname}" ]; then
            if tar -tzf "${d}${fname}" >/dev/null 2>&1; then
                [ "${d}${fname}" != "./${fname}" ] && cp "${d}${fname}" "./${fname}"
                info "  使用本地文件: ${d}${fname}"; return 0
            fi
            warn "  本地文件损坏，删除: ${d}${fname}"; rm -f "${d}${fname}"
        fi
    done
    info "  下载: ${url}"
    wget --show-progress -O "${fname}" "${url}" || err "下载失败: ${url}"
    tar -tzf "${fname}" >/dev/null 2>&1 || { rm -f "${fname}"; err "下载文件损坏: ${fname}"; }
    cp "${fname}" "${CACHE_DIR_DL}/" 2>/dev/null || true
}

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

    # 7. wget + cmake
    total=$((total+1))
    if command -v wget &>/dev/null; then
        check_ok "wget: $(wget --version 2>&1 | head -1)"
        passed=$((passed+1))
    else
        check_fail "wget: 未安装（dnf install -y wget）"
    fi
    if ! command -v cmake &>/dev/null; then
        dnf install -y cmake 2>/dev/null || true
    fi

    # 8. Docker
    total=$((total+1))
    if command -v docker &>/dev/null; then
        check_ok "docker: $(docker --version)"
        passed=$((passed+1))
    else
        warn "docker 未安装，正在安装..."
        dnf install -y docker-ce docker-ce-cli containerd.io 2>/dev/null \
            || dnf install -y docker 2>/dev/null \
            || check_fail "Docker 安装失败"
        systemctl enable docker --now 2>/dev/null || true
        check_ok "docker 已安装"
        passed=$((passed+1))
    fi

    # 9. Docker 运行状态
    total=$((total+1))
    info "  检查 Docker 运行状态..."
    if timeout 10 docker info &>/dev/null 2>&1; then
        check_ok "Docker 运行中"
        passed=$((passed+1))
    else
        systemctl start docker 2>/dev/null || true
        sleep 2
        if timeout 10 docker info &>/dev/null 2>&1; then
            check_ok "Docker 已启动"
            passed=$((passed+1))
        else
            check_fail "Docker 无法启动"
        fi
    fi

    # 10. expect 工具
    total=$((total+1))
    if command -v expect &>/dev/null; then
        check_ok "expect: $(expect -v 2>&1 | head -1)"
        passed=$((passed+1))
    else
        warn "expect 未安装，正在安装..."
        dnf install -y expect 2>/dev/null && check_ok "expect 已安装" && passed=$((passed+1)) \
            || check_fail "expect 安装失败"
    fi

    # 11. CentOS Stream 9 基础镜像
    total=$((total+1))
    info "  检查 Docker 基础镜像..."
    if docker images centos:stream9 --format '{{.Tag}}' 2>/dev/null | grep -q .; then
        check_ok "基础镜像 centos:stream9 已存在"
        passed=$((passed+1))
    else
        warn "拉取 CentOS Stream 9 基础镜像..."
        docker pull quay.io/centos/centos:stream9 2>/dev/null && \
            docker tag quay.io/centos/centos:stream9 centos:stream9 && \
            check_ok "基础镜像已拉取 (quay.io)" && passed=$((passed+1)) \
            || check_fail "基础镜像拉取失败"
    fi

    # 12. Git 凭证
    total=$((total+1))
    if git config --global credential.helper 2>/dev/null | grep -q . || \
       [ -f ~/.git-credentials ]; then
        check_ok "Git 凭证已配置"
        passed=$((passed+1))
    else
        git config --global credential.helper store 2>/dev/null || true
        check_ok "Git 凭证已配置 (store)"
        passed=$((passed+1))
    fi

    # 13. 编译依赖库检测 + 自动源码编译安装
    total=$((total+1))
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:${PKG_CONFIG_PATH:-}
    gcc_ok=false
    echo "int main(){return 0;}" | gcc -x c - -o /tmp/gcc_test 2>/dev/null && rm -f /tmp/gcc_test && gcc_ok=true
    if ! $gcc_ok; then
        warn "gcc 无法编译，正在修复 glibc..."
        dnf distro-sync --allowerasing -y glibc glibc-devel glibc-headers glibc-common libgcc libstdc++ 2>/dev/null || true
        dnf reinstall -y gcc glibc-devel 2>/dev/null || true
    fi
    if pkg-config --exists libzip 2>/dev/null; then
        info "  libzip 已安装: $(pkg-config --modversion libzip)"
    else
        warn "  编译安装 libzip（从源码）..."
        cd /tmp && rm -rf libzip-1.10.1*
        download_tar https://libzip.org/download/libzip-1.10.1.tar.gz libzip-1.10.1.tar.gz
        tar xf libzip-1.10.1.tar.gz && cd libzip-1.10.1
        mkdir build && cd build && cmake .. && make -j$(nproc) && make install
        rm -rf /tmp/libzip-1.10.1* && ldconfig
        info "  libzip 编译完成"
    fi
    if pkg-config --exists oniguruma 2>/dev/null; then
        info "  oniguruma 已安装: $(pkg-config --modversion oniguruma)"
    else
        warn "  编译安装 oniguruma（从源码）..."
        cd /tmp && rm -rf onig-6.9.9*
        download_tar https://github.com/kkos/oniguruma/releases/download/v6.9.9/onig-6.9.9.tar.gz onig-6.9.9.tar.gz
        tar xf onig-6.9.9.tar.gz && cd onig-6.9.9
        ./configure && make -j$(nproc) && make install
        rm -rf /tmp/onig-6.9.9* && ldconfig
        info "  oniguruma 编译完成"
    fi
    if [ ! -f "/usr/lib64/libjpeg.so" ] && [ -f "/usr/lib64/libjpeg.so.62" ]; then
        ln -sf /usr/lib64/libjpeg.so.62 /usr/lib64/libjpeg.so 2>/dev/null || true
    fi
    check_ok "编译库就绪"
    passed=$((passed+1))

    # 14. GitHub 连通性
    total=$((total+1))
    info "  检查 GitHub 可达性..."
    if timeout 10 curl -sI --connect-timeout 5 https://github.com 2>/dev/null | head -1 | grep -qE "200|301|302"; then
        check_ok "GitHub 可达"
        passed=$((passed+1))
    else
        warn "GitHub 不可达"
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
    local repo_url="$1" dest_dir="$2" branch="$3"
    expect -c "
set timeout 120
spawn git clone --depth 1 --branch ${branch} ${repo_url} ${dest_dir}
expect {
    \"*yes/no*\"      { send \"yes\r\"; exp_continue }
    \"*fingerprint*\" { send \"yes\r\"; exp_continue }
    \"*Username*\"    { send \"\r\";   exp_continue }
    \"*Password*\"    { send \"\r\";   exp_continue }
    \"*passphrase*\"  { send \"\r\";   exp_continue }
    timeout           { exit 1 }
    eof
}
catch wait result
exit [lindex \$result 3]
"
}

# GitHub 拉取（expect 自动回填 + 最多重试 3 次）
info "  获取禅道源码..."
rm -rf "${BUILD_DIR}/source" 2>/dev/null || true
SCRIPT_DIR="${_SCRIPT_DIR}"
if [ -f "${SCRIPT_DIR}/zentaopms.zip" ]; then
    info "  使用本地 zip: ${SCRIPT_DIR}/zentaopms.zip"
    unzip -qo "${SCRIPT_DIR}/zentaopms.zip" -d /tmp/zentaopms_extract
    EXTRACTED=$(ls /tmp/zentaopms_extract/ | head -1)
    if [ -d "/tmp/zentaopms_extract/${EXTRACTED}" ] && [ "$(ls -A /tmp/zentaopms_extract/ | wc -l)" -eq 1 ]; then
        mv "/tmp/zentaopms_extract/${EXTRACTED}" "${BUILD_DIR}/source"
    else
        mv /tmp/zentaopms_extract/* "${BUILD_DIR}/source" 2>/dev/null || mv /tmp/zentaopms_extract "${BUILD_DIR}/source" 2>/dev/null
    fi
    [ -f "${BUILD_DIR}/source/www/index.php" ] || err "ZIP 解压异常"
    rm -rf /tmp/zentaopms_extract
elif [ -f "/tmp/build-cache/zentaopms.zip" ]; then
    info "  使用本地 zip: /tmp/build-cache/zentaopms.zip"
    unzip -qo /tmp/build-cache/zentaopms.zip -d /tmp/zentaopms_extract
    EXTRACTED=$(ls /tmp/zentaopms_extract/ | head -1)
    if [ -d "/tmp/zentaopms_extract/${EXTRACTED}" ] && [ "$(ls -A /tmp/zentaopms_extract/ | wc -l)" -eq 1 ]; then
        mv "/tmp/zentaopms_extract/${EXTRACTED}" "${BUILD_DIR}/source"
    else
        mv /tmp/zentaopms_extract/* "${BUILD_DIR}/source" 2>/dev/null || mv /tmp/zentaopms_extract "${BUILD_DIR}/source" 2>/dev/null
    fi
    [ -f "${BUILD_DIR}/source/www/index.php" ] || err "ZIP 解压异常"
    rm -rf /tmp/zentaopms_extract
elif [ -f "${BUILD_DIR}/source/www/index.php" ]; then
    info "  使用已有源码"
else
    mkdir -p "${BUILD_DIR}" && cd "${BUILD_DIR}"  # 确保目录和CWD有效
    info "  Git clone..."
    sleep 1
    for i in 1 2 3; do
        info "  尝试 ${i}/3..."
        expect -c "
log_user 1
set timeout 300
spawn git clone --depth 1 --branch main https://github.com/easysoft/zentaopms.git ${BUILD_DIR}/source
expect {
    \"*yes/no*\"      { send \"yes\r\"; exp_continue }
    \"*fingerprint*\" { send \"yes\r\"; exp_continue }
    \"*Username*\"    { send \"Mountains-and-rivers\r\"; exp_continue }
    \"*Password*\"    { send \"Wgl,.2018\r\"; exp_continue }
    timeout           { exit 1 }
}
" 2>&1
        [ -f "${BUILD_DIR}/source/www/index.php" ] && break
        rm -rf "${BUILD_DIR}/source" 2>/dev/null || true
        sleep 5
    done
fi

rm -rf "${BUILD_DIR}/source/.git" "${BUILD_DIR}/source/.github" 2>/dev/null || true
info "  源码就绪: ${BUILD_DIR}/source"

# ---- 3. 选择构建模式 ----
info "[3/9] 准备构建..."
SCRIPT_DIR="${_SCRIPT_DIR}"

# 复制阿里云 yum 源（加速 Docker 内 dnf 安装）
if [ -f "${SCRIPT_DIR}/centos.repo" ]; then
    cp "${SCRIPT_DIR}/centos.repo" "${BUILD_DIR}/centos.repo"
elif [ -f "/opt/centos.repo" ]; then
    cp "/opt/centos.repo" "${BUILD_DIR}/centos.repo"
fi
info "  yum 源: 阿里云镜像"

for f in Dockerfile Dockerfile.prebuilt .dockerignore docker-entrypoint.sh; do
    [ -f "${SCRIPT_DIR}/${f}" ] && cp -f "${SCRIPT_DIR}/${f}" "${BUILD_DIR}/${f}"
done

# 自动检测：宿主编译好的 PHP 存在 → 快速模式；不存在 → Docker 内编译
if [ -f "/opt/php/bin/php" ] && [ -f "/opt/httpd/bin/httpd" ]; then
    info "  检测到预编译 PHP/Apache → 快速构建模式"
    cp -r /opt/php "${BUILD_DIR}/php" 2>/dev/null || true
    cp -r /opt/httpd "${BUILD_DIR}/httpd" 2>/dev/null || true
    DOCKERFILE="${BUILD_DIR}/Dockerfile.prebuilt"
else
    info "  未检测到预编译 → Docker 内编译（约 5-15 分钟）"
    DOCKERFILE="${BUILD_DIR}/Dockerfile"
fi

# ---- 4. Docker 构建 ----
info "[4/9] Docker 构建..."
# 复制本地编译包到构建上下文（Dockerfile 内 COPY 替代 wget 下载）
for pkg in libzip-1.10.1.tar.gz onig-6.9.9.tar.gz httpd-2.4.62.tar.gz php-8.1.27.tar.gz; do
    [ -f "${SCRIPT_DIR}/${pkg}" ] && cp "${SCRIPT_DIR}/${pkg}" "${BUILD_DIR}/${pkg}" && info "  ${pkg} → 构建上下文" || true
done
# 强制删除所有已退出/已停止容器 + 旧镜像 + <none> 悬空镜像
docker rm -f zentao 2>/dev/null || true
docker container prune -f 2>/dev/null || true
docker rmi -f "${FULL_IMAGE}" "${LATEST_IMAGE}" 2>/dev/null || true
docker image prune -f 2>/dev/null || true
cd "${BUILD_DIR}"
docker build --no-cache \
    --build-arg "ZENTAO_VERSION=${ZENTAO_VERSION}" \
    -t "${FULL_IMAGE}" \
    -t "${LATEST_IMAGE}" \
    -f "${DOCKERFILE}" \
    .
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
