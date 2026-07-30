#!/bin/bash
# ============================================================
# GitLab CE — CentOS 9 源码构建（企业级离线优先）
# 参考: https://docs.gitlab.com/ee/install/installation.html
# 官方仅支持 Debian/Ubuntu，此脚本将依赖映射到 CentOS 9
#
# 用法: bash build_gitlab_source.sh [版本分支] [--skip-ruby] [--skip-go] [--skip-node]
# 示例: bash build_gitlab_source.sh 19-3-stable
#       bash build_gitlab_source.sh 19-3-stable --skip-ruby --skip-go
# ============================================================
set -euo pipefail

GITLAB_BRANCH="${1:-19-3-stable}"      # Git 分支（用于 clone 回退）
GITLAB_VER="${2:-19.3.0-pre}"          # 版本号（用于匹配本地包文件名）
GITLAB_HOME="${GITLAB_HOME:-/home/git}"
GITLAB_DIR="${GITLAB_HOME}/gitlab"
SKIP_RUBY=false; SKIP_GO=false; SKIP_NODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-ruby) SKIP_RUBY=true; shift ;;
        --skip-go)   SKIP_GO=true;   shift ;;
        --skip-node) SKIP_NODE=true; shift ;;
        *) shift ;;
    esac
done

# ── 源码仓库（官方地址） ──
GITLAB_REPO="https://gitlab.com/gitlab-org/gitlab-foss.git"
GITALY_REPO="https://gitlab.com/gitlab-org/gitaly.git"
SHELL_REPO="https://gitlab.com/gitlab-org/gitlab-shell.git"
PAGES_REPO="https://gitlab.com/gitlab-org/gitlab-pages.git"
# 注意: gitlab-workhorse 已合并进 gitlab-foss 主仓库（源码位于 gitlab-foss/workhorse/）
#       本脚本仍保留 workhorse 独立编译（兼容旧版本）

# ── 版本要求（GitLab 19.x） ──
RUBY_VERSION="3.3.9"
GO_VERSION="1.26.4"
NODE_VERSION="20.18.0"

# ── UI ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

# ── 本地源码包优先 ──
# 搜索: 脚本目录 → /tmp/build-cache/
# 参数: $1=组件名(如 gitlab-foss/gitaly/gitlab-shell/gitlab-pages)
#       $2=目标目录
load_source_tar() {
    local name="$1" dest="$2"
    for d in "${_SCRIPT_DIR}/" "/tmp/build-cache/"; do
        local f
        f=$(ls "${d}/${name}-"*.tar.xz 2>/dev/null | head -1) || true
        if [ -n "${f}" ] && [ -s "${f}" ]; then
            info "  解压本地: $(basename ${f}) ($(du -h ${f} | cut -f1))"
            mkdir -p "${dest}"
            tar -xJf "${f}" -C "${dest}"
            return 0
        fi
    done
    return 1
}

echo "============================================"
echo "  GitLab CE 源码构建 — CentOS 9"
echo "  分支: ${GITLAB_BRANCH}"
echo "  Ruby ${RUBY_VERSION} | Go ${GO_VERSION} | Node ${NODE_VERSION}"
echo "============================================"

# ═══════════════════════════════════════════════
# 0. 环境检查
# ═══════════════════════════════════════════════
step "[0/13] 环境检查..."
[ "$(id -u)" -eq 0 ] || err "需要 root 权限"
FAILED=0

MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
[ "${MEM_MB}" -ge 3800 ] && info "  内存 ${MEM_MB}MB" || { warn "  内存 ${MEM_MB}MB (建议 >= 4GB)"; FAILED=1; }

DISK_GB=$(df -BG /opt 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
[ -n "${DISK_GB}" ] && [ "${DISK_GB}" -ge 25 ] \
    && info "  磁盘 ${DISK_GB}GB" \
    || { warn "  磁盘 ${DISK_GB:-?}GB (建议 >= 25GB)"; FAILED=1; }

command -v curl &>/dev/null || { dnf install -y curl 2>/dev/null || true; }

[ $FAILED -eq 1 ] && err "环境检查未通过"

# ═══════════════════════════════════════════════
# 1. 系统编译依赖
# ═══════════════════════════════════════════════
step "[1/13] 系统编译依赖..."

# ── 配置阿里云 YUM 镜像（国内加速）──
if [ -f "${_SCRIPT_DIR}/centos.repo" ]; then
    info "  配置阿里云镜像: ${_SCRIPT_DIR}/centos.repo"
    cp /etc/yum.repos.d/centos.repo /etc/yum.repos.d/centos.repo.backup 2>/dev/null || true
    cp "${_SCRIPT_DIR}/centos.repo" /etc/yum.repos.d/centos.repo
    dnf clean all
    dnf makecache
fi

dnf install -y epel-release 2>/dev/null || true
# CRB (CodeReady Builder): libyaml-devel / gdbm-devel 等在此仓库
# centos.repo 已包含 [crb] 镜像源
dnf config-manager --set-enabled crb 2>/dev/null || true

dnf install -y --setopt=tsflags=nodocs \
    gcc gcc-c++ make cmake pkg-config autoconf automake \
    meson ninja-build \
    git curl wget patch tar bzip2 xz \
    zlib-devel openssl-devel readline-devel \
    libxml2-devel libxslt-devel libicu-devel \
    libcurl-devel expat-devel pcre2-devel \
    libyaml-devel libffi-devel gdbm-devel re2-devel \
    ncurses-devel perl perl-Image-ExifTool \
    postgresql-devel \
    GraphicsMagick postfix logrotate rsync
info "  ✓ 编译工具链就绪"

# ═══════════════════════════════════════════════
# 2. 离线包完整性检查
# ═══════════════════════════════════════════════
step "[2/13] 离线包完整性检查..."

MISSING=0
check_pkg() {
    local pattern="$1" desc="$2" url="$3"
    local found
    found=$(ls "${_SCRIPT_DIR}/"${pattern} 2>/dev/null | head -1) || true
    if [ -n "${found}" ] && [ -s "${found}" ]; then
        info "  ✓ $(basename ${found}) ($(du -h "${found}" | cut -f1))"
    else
        warn "  ✗ ${pattern} — ${desc}"
        echo "      下载: ${url}"
        MISSING=$((MISSING + 1))
    fi
}

check_pkg "gitlab-foss-"*.tar.xz \
    "GitLab FOSS 主应用源码" \
    "git clone --depth 1 -b ${GITLAB_BRANCH} https://github.com/gitlabhq/gitlabhq.git"

check_pkg "gitaly-"*.tar.xz \
    "Gitaly Git RPC 服务" \
    "https://gitlab.com/gitlab-org/gitaly.git"

check_pkg "gitlab-shell-"*.tar.xz \
    "GitLab Shell SSH 接口" \
    "https://gitlab.com/gitlab-org/gitlab-shell.git"
# workhorse 已合并进 gitlab-foss，无需单独检查

if ! ${SKIP_RUBY}; then
    check_pkg "ruby-${RUBY_VERSION}.tar.gz" \
        "Ruby ${RUBY_VERSION} 运行时" \
        "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.gz"
fi

if ! ${SKIP_GO}; then
    check_pkg "go${GO_VERSION}.linux-amd64.tar.gz" \
        "Go ${GO_VERSION} 运行时" \
        "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
fi

if ! ${SKIP_NODE}; then
    check_pkg "node-v${NODE_VERSION}-linux-x64.tar.xz" \
        "Node.js ${NODE_VERSION} 运行时" \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
fi

[ ${MISSING} -gt 0 ] && err "离线包缺失 ${MISSING} 个（以上列出下载地址，放入 ${_SCRIPT_DIR}/ 即可）"
info "  ✓ 离线包全部就绪"

# ═══════════════════════════════════════════════
# 3. Git（通过 Gitaly 编译）
# ═══════════════════════════════════════════════
step "[3/13] Git（Gitaly 提供）..."

if command -v git &>/dev/null && git --version 2>&1 | grep -qE '2\.4[2-9]|2\.[5-9]'; then
    info "  ✓ Git $(git --version)"
else
    info "  从 Gitaly 编译 Git..."
    rm -rf /tmp/gitaly-build
    if load_source_tar "gitaly" "/tmp/gitaly-build"; then
        cd /tmp/gitaly-build
        [ -f Makefile ] || err "Gitaly Makefile 缺失，源码包不完整"
    else
        git clone --depth 1 "${GITALY_REPO}" /tmp/gitaly-build
    fi
    cd /tmp/gitaly-build
    make git GIT_PREFIX=/usr/local
    cd /tmp; rm -rf /tmp/gitaly-build
    info "  ✓ Git $(git --version)"
fi

# ═══════════════════════════════════════════════
# 4. Ruby 3.3.x
# ═══════════════════════════════════════════════
step "[4/13] Ruby ${RUBY_VERSION}..."

if ${SKIP_RUBY}; then
    info "  --skip-ruby"
elif [ -x /usr/local/ruby/bin/ruby ] && /usr/local/ruby/bin/ruby --version 2>&1 | grep -q "${RUBY_VERSION}"; then
    info "  ✓ Ruby $(/usr/local/ruby/bin/ruby --version)"
else
    RUBY_SRC="ruby-${RUBY_VERSION}.tar.gz"
    if [ -f "${_SCRIPT_DIR}/${RUBY_SRC}" ]; then
        info "  使用本地: ${RUBY_SRC} ($(du -h "${_SCRIPT_DIR}/${RUBY_SRC}" | cut -f1))"
        cp "${_SCRIPT_DIR}/${RUBY_SRC}" "/tmp/${RUBY_SRC}"
    else
        RUBY_URL="https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/${RUBY_SRC}"
        info "  下载: ${RUBY_URL}"
        for i in 1 2 3; do
            wget -q --show-progress -O "/tmp/${RUBY_SRC}" "${RUBY_URL}" 2>/dev/null \
                || curl -L -o "/tmp/${RUBY_SRC}" "${RUBY_URL}" \
                && break
            warn "  下载重试 (${i}/3)"; sleep 5
        done
        [ -f "/tmp/${RUBY_SRC}" ] && [ -s "/tmp/${RUBY_SRC}" ] || err "Ruby 下载失败"
    fi

    rm -rf /tmp/ruby-src /usr/local/ruby
    mkdir -p /tmp/ruby-src
    tar -xzf "/tmp/${RUBY_SRC}" -C /tmp/ruby-src --strip-components=1
    cd /tmp/ruby-src

    info "  ./configure..."
    ./configure --prefix=/usr/local/ruby --enable-shared --disable-install-doc 
    info "  make -j$(nproc)..."
    make -j$(nproc) 
    info "  make install..."
    make install 
    ln -sf /usr/local/ruby/bin/* /usr/local/bin/
    cd /tmp; rm -rf /tmp/ruby-src "/tmp/${RUBY_SRC}"

    # RubyGems
    gem update --system --no-document
    info "  ✓ $(ruby --version)"
fi

# ═══════════════════════════════════════════════
# 5. Go
# ═══════════════════════════════════════════════
step "[5/13] Go ${GO_VERSION}..."

if ${SKIP_GO}; then
    info "  --skip-go"
elif [ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version 2>&1 | grep -q "${GO_VERSION}"; then
    info "  ✓ $(/usr/local/go/bin/go version)"
else
    GO_TGZ="go${GO_VERSION}.linux-amd64.tar.gz"
    if [ -f "${_SCRIPT_DIR}/${GO_TGZ}" ]; then
        info "  使用本地: ${GO_TGZ} ($(du -h "${_SCRIPT_DIR}/${GO_TGZ}" | cut -f1))"
        cp "${_SCRIPT_DIR}/${GO_TGZ}" "/tmp/${GO_TGZ}"
    else
        GO_URL="https://go.dev/dl/${GO_TGZ}"
        info "  下载: ${GO_URL}"
        for i in 1 2 3; do
            wget -q --show-progress -O "/tmp/${GO_TGZ}" "${GO_URL}" 2>/dev/null \
                || curl -L -o "/tmp/${GO_TGZ}" "${GO_URL}" \
                && break
            warn "  重试 (${i}/3)"; sleep 5
        done
        [ -f "/tmp/${GO_TGZ}" ] && [ -s "/tmp/${GO_TGZ}" ] || err "Go 下载失败"
    fi

    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${GO_TGZ}"
    ln -sf /usr/local/go/bin/* /usr/local/bin/
    rm -f "/tmp/${GO_TGZ}"
    info "  ✓ $(go version)"
fi

# 配置 Go 国内代理 + 模块模式
go env -w GO111MODULE=on
go env -w GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy,direct
go env -w GOFLAGS=-v
info "  ✓ GOPROXY=https://goproxy.cn  GO111MODULE=on  GOFLAGS=-v"

# ═══════════════════════════════════════════════
# 6. Node.js 20.x + Yarn
# ═══════════════════════════════════════════════
step "[6/13] Node.js ${NODE_VERSION}..."

if ${SKIP_NODE}; then
    info "  --skip-node"
elif command -v node &>/dev/null && node --version 2>&1 | grep -q 'v20'; then
    info "  ✓ Node $(node --version)"
else
    NODE_TGZ="node-v${NODE_VERSION}-linux-x64.tar.xz"
    if [ -f "${_SCRIPT_DIR}/${NODE_TGZ}" ]; then
        info "  使用本地: ${NODE_TGZ} ($(du -h "${_SCRIPT_DIR}/${NODE_TGZ}" | cut -f1))"
        cp "${_SCRIPT_DIR}/${NODE_TGZ}" "/tmp/${NODE_TGZ}"
    else
        NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TGZ}"
        NODE_MIRROR="https://npmmirror.com/mirrors/node/v${NODE_VERSION}/${NODE_TGZ}"
        info "  下载: ${NODE_URL}"
        for i in 1 2 3; do
            wget -q --show-progress -O "/tmp/${NODE_TGZ}" "${NODE_URL}" 2>/dev/null \
                || wget -q --show-progress -O "/tmp/${NODE_TGZ}" "${NODE_MIRROR}" 2>/dev/null \
                || curl -L -o "/tmp/${NODE_TGZ}" "${NODE_MIRROR}" \
                && break
            warn "  重试 (${i}/3)"; sleep 5
        done
        [ -f "/tmp/${NODE_TGZ}" ] && [ -s "/tmp/${NODE_TGZ}" ] || err "Node 下载失败"
    fi

    tar -C /usr/local --strip-components=1 -xJf "/tmp/${NODE_TGZ}"
    rm -f "/tmp/${NODE_TGZ}"

    # 配置 npm / yarn 国内镜像
    npm config set registry https://registry.npmmirror.com
    yarn config set registry https://registry.npmmirror.com 2>/dev/null || true
    info "  ✓ npm/yarn registry: https://registry.npmmirror.com"

    npm install -g yarn
    info "  ✓ Node $(node --version), Yarn $(yarn --version)"
fi

# ═══════════════════════════════════════════════
# 7. 用户 & 目录
# ═══════════════════════════════════════════════
step "[7/13] 创建 git 用户..."

id git &>/dev/null || useradd -r -m -d "${GITLAB_HOME}" -s /bin/bash -c 'GitLab' git
mkdir -p "${GITLAB_HOME}/.ssh" "${GITLAB_HOME}/repositories"
chown -R git:git "${GITLAB_HOME}"
chmod 700 "${GITLAB_HOME}/.ssh"
info "  ✓ git 用户: ${GITLAB_HOME}"

# ═══════════════════════════════════════════════
# 8. PostgreSQL 检查
# ═══════════════════════════════════════════════
step "[8/13] 检查 PostgreSQL 16+..."

if command -v psql &>/dev/null && psql --version 2>&1 | grep -qE '1[6-9]\.'; then
    info "  ✓ PostgreSQL $(psql --version | awk '{print $3}')"
else
    warn "  未检测到 PostgreSQL 16+"
    PG_SCRIPT="${_SCRIPT_DIR}/../../postgresql16/install_postgresql.sh"
    if [ -f "${PG_SCRIPT}" ]; then
        info "  自动执行: bash ${PG_SCRIPT}"
        bash "${PG_SCRIPT}" || err "PostgreSQL 安装失败"
    else
        warn "  请手动执行: bash ../postgresql16/install_postgresql.sh"
    fi
fi

# ═══════════════════════════════════════════════
# 9. Redis 检查
# ═══════════════════════════════════════════════
step "[9/13] 检查 Redis 7+..."

if command -v redis-server &>/dev/null && redis-server --version 2>&1 | grep -q 'v=7'; then
    info "  ✓ Redis $(redis-server --version | awk '{print $3}')"
else
    warn "  未检测到 Redis 7+"
    REDIS_SCRIPT="${_SCRIPT_DIR}/../../redis7/install_redis.sh"
    if [ -f "${REDIS_SCRIPT}" ]; then
        info "  自动执行: bash ${REDIS_SCRIPT}"
        bash "${REDIS_SCRIPT}" || err "Redis 安装失败"
    else
        warn "  请手动执行: bash ../redis7/install_redis.sh"
    fi
fi

# ═══════════════════════════════════════════════
# 10. 克隆 GitLab FOSS
# ═══════════════════════════════════════════════
step "[10/13] 部署 GitLab FOSS 源码..."

if [ -f "${GITLAB_DIR}/Gemfile" ]; then
    info "  ${GITLAB_DIR} 已存在，跳过克隆"
elif load_source_tar "gitlab-foss" "${GITLAB_DIR}"; then
    info "  ✓ 从本地 tar.xz 解压"
    chown -R git:git "${GITLAB_DIR}"
else
    info "  git clone ${GITLAB_REPO} -b ${GITLAB_BRANCH}"
    sudo -u git -H git clone --depth 1 "${GITLAB_REPO}" -b "${GITLAB_BRANCH}" "${GITLAB_DIR}"
fi
[ -f "${GITLAB_DIR}/Gemfile" ] || err "GitLab 源码部署失败: ${GITLAB_DIR}/Gemfile 不存在"
info "  ✓ ${GITLAB_DIR}"

# ═══════════════════════════════════════════════
# 11. 配置 GitLab
# ═══════════════════════════════════════════════
step "[11/13] 配置 GitLab..."

cd "${GITLAB_DIR}"

# gitlab.yml
if [ ! -f config/gitlab.yml ] || [ ! -s config/gitlab.yml ]; then
    sudo -u git -H cp config/gitlab.yml.example config/gitlab.yml
    sudo -u git -H sed -i "s|host: localhost|host: $(hostname -I | awk '{print $1}')|" config/gitlab.yml
    info "  ✓ gitlab.yml"
else
    info "  ✓ gitlab.yml (已存在)"
fi

# database.yml
if [ ! -f config/database.yml ] || [ ! -s config/database.yml ]; then
    sudo -u git -H cp config/database.yml.postgresql config/database.yml
    sudo -u git -H sed -i 's|username: git|username: postgres|' config/database.yml
    sudo -u git -H sed -i 's|password:.*|password: Pg1@zendao2024|' config/database.yml
    sudo -u git -H sed -i 's|host:.*|host: 127.0.0.1|' config/database.yml
    info "  ✓ database.yml"
else
    info "  ✓ database.yml (已存在)"
fi

# secrets.yml
if [ ! -f config/secrets.yml ] || [ ! -s config/secrets.yml ]; then
    sudo -u git -H cp config/secrets.yml.example config/secrets.yml
    sudo -u git -H chmod 0600 config/secrets.yml
    info "  ✓ secrets.yml"
else
    info "  ✓ secrets.yml (已存在)"
fi

# puma.rb — Web 服务器配置（官方正式要求）
if [ ! -f config/puma.rb ] || [ ! -s config/puma.rb ]; then
    sudo -u git -H cp config/puma.rb.example config/puma.rb
    info "  ✓ puma.rb"
else
    info "  ✓ puma.rb (已存在)"
fi

# resque.yml — 后台任务配置
if [ ! -f config/resque.yml ] || [ ! -s config/resque.yml ]; then
    sudo -u git -H cp config/resque.yml.example config/resque.yml 2>/dev/null || true
    # 注入 Redis 密码
    sudo -u git -H sed -i 's|# redis.*|redis: redis://:Pg1@zendao2024@127.0.0.1:6379|' config/resque.yml 2>/dev/null || true
    info "  ✓ resque.yml"
else
    info "  ✓ resque.yml (已存在)"
fi

# cable.yml — ActionCable 配置（GitLab 17.x 需要）
if [ ! -f config/cable.yml ] || [ ! -s config/cable.yml ]; then
    sudo -u git -H cp config/cable.yml.example config/cable.yml 2>/dev/null || true
    # 注入 Redis 密码
    sudo -u git -H sed -i 's|url:.*|url: redis://:Pg1@zendao2024@127.0.0.1:6379|' config/cable.yml 2>/dev/null || true
    info "  ✓ cable.yml"
else
    info "  ✓ cable.yml (已存在)"
fi

# 目录权限
sudo -u git -H mkdir -p log tmp/pids tmp/sockets public/uploads builds shared/artifacts shared/pages shared/registry shared/terraform_state
chown -R git log tmp public/uploads builds shared/
chmod -R u+rwX,go-w log/ tmp/ public/uploads/ builds/ shared/
info "  ✓ 目录权限已设置"

# ═══════════════════════════════════════════════
# 12. 安装 Ruby Gems
# ═══════════════════════════════════════════════
step "[12/13] 安装 Ruby Gems..."

cd "${GITLAB_DIR}"

if [ -d "vendor/bundle/ruby" ]; then
    GEM_COUNT=$(find vendor/bundle -name '*.gemspec' 2>/dev/null | wc -l)
    if [ "${GEM_COUNT}" -gt 50 ]; then
        info "  ✓ Gems 已安装 (${GEM_COUNT} gems)，跳过 bundle install"
    else
        info "  vendor/bundle 不完整 (${GEM_COUNT} gems)，重新安装..."
        rm -rf vendor/bundle .bundle
    fi
fi

if [ ! -d "vendor/bundle/ruby" ]; then
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:$PATH" bundle config set --local deployment 'true'
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:$PATH" bundle config set --local without 'development test kerberos'
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:$PATH" bundle config path "${GITLAB_DIR}/vendor/bundle"
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:$PATH" bundle install -j$(nproc)
    info "  ✓ Gems 安装完成"
fi

# ═══════════════════════════════════════════════
# 13. 编译安装 GitLab 子组件
# ═══════════════════════════════════════════════
step "[13/13] 编译安装 GitLab 子组件..."

	# Go proxy (root + git user, go env -w + export)
	sudo -u git -H go env -w GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy,direct 2>/dev/null || true
	sudo -u git -H go env -w GO111MODULE=on 2>/dev/null || true
	sudo -u git -H go env -w GOFLAGS=-v 2>/dev/null || true
	sudo -u git -H go env -w GONOSUMDB=* 2>/dev/null || true
	go env -w GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy,direct 2>/dev/null || true
	go env -w GONOSUMDB=* 2>/dev/null || true
	go env -w GO111MODULE=on 2>/dev/null || true
	export GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy,direct
	export GO111MODULE=on
	export GOFLAGS=-v
	export GONOSUMDB=*
	export GONOSUMCHECK=*
	export GOPRIVATE=

cd "${GITLAB_DIR}"

_GITALY_DST="${GITLAB_HOME}/gitaly"
_SHELL_DST="${GITLAB_HOME}/gitlab-shell"
_WORKHORSE_DST="${GITLAB_HOME}/gitlab-workhorse"

# ── Gitaly ──
_GITALY_BIN="${_GITALY_DST}/_build/bin/gitaly"  # meson 构建输出路径

if [ -f "${_GITALY_BIN}" ] && "${_GITALY_BIN}" --version &>/dev/null 2>&1; then
    info "  ✓ Gitaly 已编译"
else
    if load_source_tar "gitaly" "${_GITALY_DST}"; then
        chown -R git:git "${_GITALY_DST}"
    elif [ ! -f "${_GITALY_DST}/Makefile" ]; then
        info "  克隆 Gitaly..."
        sudo -u git -H git clone --depth 1 "${GITALY_REPO}" "${_GITALY_DST}"
    fi
    cd "${_GITALY_DST}"
    info "  编译 Gitaly..."
    GOPROXY=https://goproxy.cn,direct GONOSUMDB=* GONOSUMCHECK=* GOFLAGS=-v GO111MODULE=on make 2>&1 || err "Gitaly 编译失败"
    [ -f "${_GITALY_BIN}" ] || err "Gitaly 编译产物缺失: ${_GITALY_BIN}"
    info "  ✓ Gitaly 编译完成"
fi

# ── GitLab Shell ──
if [ -f "${_SHELL_DST}/bin/gitlab-shell" ] || [ -f "${_SHELL_DST}/Makefile" ]; then
    info "  ✓ gitlab-shell（本地 tar.xz）"
else
    info "  安装 gitlab-shell..."
    cd "${GITLAB_DIR}"
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:$PATH" bundle exec rake gitlab:shell:install RAILS_ENV=production
fi

# ── GitLab Workhorse ──
if [ -f "${_WORKHORSE_DST}/gitlab-workhorse" ] && "${_WORKHORSE_DST}/gitlab-workhorse" -version &>/dev/null 2>&1; then
    info "  ✓ gitlab-workhorse 已编译"
else
    if load_source_tar "gitlab-workhorse" "${_WORKHORSE_DST}"; then
        chown -R git:git "${_WORKHORSE_DST}"
        cd "${_WORKHORSE_DST}"
        info "  编译 gitlab-workhorse..."
        make 2>&1 || err "gitlab-workhorse 编译失败"
    elif [ ! -f "${_WORKHORSE_DST}/Makefile" ]; then
        cd "${GITLAB_DIR}"
        info "  安装 gitlab-workhorse..."
        sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:$PATH" bundle exec rake "gitlab:workhorse:install[${_WORKHORSE_DST}]" RAILS_ENV=production
        cd "${_WORKHORSE_DST}"
        make 2>&1 || true
    fi
    info "  ✓ gitlab-workhorse 就绪"
fi

# ── GitLab Pages（可选） ──
_PAGES_DST="${GITLAB_HOME}/gitlab-pages"
if [ -f "${_PAGES_DST}/gitlab-pages" ]; then
    info "  ✓ gitlab-pages 已编译"
elif load_source_tar "gitlab-pages" "${_PAGES_DST}"; then
    chown -R git:git "${_PAGES_DST}"
    cd "${_PAGES_DST}"
    make 2>&1 || warn "gitlab-pages 编译有警告（可选组件）"
    info "  ✓ gitlab-pages 编译完成"
else
    info "  ⚩ gitlab-pages（跳过，非必需）"
fi

# ═══════════════════════════════════════════════
# 构建产物清单
# ═══════════════════════════════════════════════
echo ""
echo "============================================"
echo "  GitLab CE 源码构建完成"
echo ""
echo "  构建产物清单:"
echo "    Ruby:    /usr/local/ruby  ($(ruby --version 2>&1))"
echo "    Go:      /usr/local/go    ($(go version 2>&1))"
echo "    Node:    $(which node)    ($(node --version 2>&1))"
echo "    GitLab:  ${GITLAB_DIR}"
echo "    Gitaly:  ${_GITALY_DST}"
echo "    Shell:   ${_SHELL_DST}"
echo "    Workhorse: ${_WORKHORSE_DST}"
echo ""
echo "  下一步:"
echo "    bash install_gitlab_source.sh ${GITLAB_BRANCH} gitlab.testops.local"
echo "============================================"
