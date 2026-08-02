#!/bin/bash
# ============================================================
# GitLab CE — 源码安装启动（裸机 CentOS 9）
# 参考: https://docs.gitlab.com/ee/install/installation.html
# 前提: 先执行 build_gitlab_source.sh 完成编译构建
#
# 用法: bash install_gitlab_source.sh [域名/IP] [--port 80] [--pass Gitlab12345]
# 示例: bash install_gitlab_source.sh gitlab.testops.local
#       bash install_gitlab_source.sh 192.168.0.102 --port 8080 --pass MyPass123
# ============================================================
set -euo pipefail

# ── 配置 ──
GITLAB_DOMAIN="${1:-gitlab.testops.local}"
GITLAB_PORT="${GITLAB_PORT:-80}"
ROOT_PASS="${GITLAB_ROOT_PASSWORD:-Gitlab12345}"

# 加载远程 Redis / PostgreSQL 配置（默认连接本机）
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
if [ -f "${_SCRIPT_DIR}/gitlab_remote.conf" ]; then
    source "${_SCRIPT_DIR}/gitlab_remote.conf"
fi
# 默认值（remote.conf 不存在或未设置时）
REMOTE="${REMOTE:-false}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-Pg1@zendao2024}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-Pg1@zendao2024}"
# Redis URL 中 @ 需编码为 %40
_REDIS_PW_ENCODED="${REDIS_PASSWORD//@/%40}"
GITLAB_HOME="${GITLAB_HOME:-/home/git}"
GITLAB_DIR="${GITLAB_HOME}/gitlab"
GITALY_DIR="${GITLAB_HOME}/gitaly"
SHELL_DIR="${GITLAB_HOME}/gitlab-shell"
WORKHORSE_DIR="${GITLAB_HOME}/gitlab-workhorse"
LOG_DIR="${LOG_DIR:-/var/log/gitlab}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) GITLAB_PORT="$2"; shift 2 ;;
        --pass) ROOT_PASS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# ── UI ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"

[ "$(id -u)" -eq 0 ] || err "需要 root 权限"

echo "============================================"
echo "  GitLab CE 源码安装启动"
echo "  域名:      ${GITLAB_DOMAIN}"
echo "  端口:      ${GITLAB_PORT}"
echo "  源码目录:  ${GITLAB_DIR}"
echo "============================================"

# ═══════════════════════════════════════════════
# 0. 环境检查
# ═══════════════════════════════════════════════
step "[0/7] 环境检查..."

# 修复 Windows CRLF 换行符（源码包在 Windows 解压后可能残留 \r）
# 扫描关键目录，全量清理（scripts/ config/ bin/ 等），不留死角
_CRLF_FILES=$(grep -rl $'\r' "${GITLAB_DIR}/scripts" "${GITLAB_DIR}/bin" "${GITLAB_DIR}/config" 2>/dev/null | wc -l || echo 0)
if [ "${_CRLF_FILES}" -gt 0 ]; then
    info "  检测到 ${_CRLF_FILES} 个文件含 Windows 换行符，开始清理..."
    # 用 find -exec 替代 xargs（规避 ARG_MAX 参数上限）
    find "${GITLAB_DIR}/scripts" "${GITLAB_DIR}/bin" "${GITLAB_DIR}/config" -type f \
        -exec grep -lq $'\r' {} \; -exec sed -i 's/\r//g' {} + 2>/dev/null || true
    # 也修复已知会导致 Permission denied 的脚本文件
    for _f in "${GITLAB_DIR}/scripts/build_frontend_islands" "${GITLAB_DIR}/scripts/frontend/start_storybook.sh"; do
        [ -f "${_f}" ] && sed -i 's/\r//g' "${_f}" 2>/dev/null || true
    done
    # 确认清理后的文件不再含 \r（|| true 防止 pipefail 下 grep 无匹配时 exit 1 触发 ERR）
    _REMAIN=$(grep -rl $'\r' "${GITLAB_DIR}/scripts" "${GITLAB_DIR}/bin" "${GITLAB_DIR}/config" 2>/dev/null | wc -l || echo 0)
    info "  ✓ CRLF 已清理（修复前: ${_CRLF_FILES} 个，修复后: ${_REMAIN} 个）"
fi
FAILED=0

# 检查 git 用户
id git &>/dev/null && info "  ✓ git 用户" || { warn "  ✗ git 用户不存在，请先执行 build_gitlab_source.sh"; FAILED=1; }

# 检查源码目录
[ -f "${GITLAB_DIR}/Gemfile" ] && info "  ✓ 源码: ${GITLAB_DIR}" \
    || { warn "  ✗ 源码不存在: ${GITLAB_DIR}，请先执行 build_gitlab_source.sh"; FAILED=1; }

# 检查 Gitaly
[ -f "${GITALY_DIR}/_build/bin/gitaly" ] && info "  ✓ Gitaly: ${GITALY_DIR}" \
    || { warn "  ✗ Gitaly 未编译: ${GITALY_DIR}"; FAILED=1; }

# 检查 GitLab Shell
[ -f "${SHELL_DIR}/bin/gitlab-shell" ] || [ -d "${SHELL_DIR}/.git" ] \
    && info "  ✓ gitlab-shell: ${SHELL_DIR}" \
    || { warn "  ✗ gitlab-shell 缺失: ${SHELL_DIR}"; FAILED=1; }

# ── 生成 gitlab-shell config.yml（SSH clone 必需）──
if [ -f "${SHELL_DIR}/config.yml.example" ] && [ ! -f "${SHELL_DIR}/config.yml" ]; then
    sed 's|gitlab_url: http://localhost:8080|gitlab_url: http://127.0.0.1:3000|' "${SHELL_DIR}/config.yml.example" > "${SHELL_DIR}/config.yml"
    sed -i 's|secret_file: .*|secret_file: '"${GITLAB_DIR}"'/.gitlab_shell_secret|' "${SHELL_DIR}/config.yml"
    chown git:git "${SHELL_DIR}/config.yml"
    chmod 640 "${SHELL_DIR}/config.yml"
    chown -R git:git "${SHELL_DIR}/bin/" 2>/dev/null || true
    info "  ✓ gitlab-shell config.yml 已生成"
elif [ -f "${SHELL_DIR}/config.yml" ]; then
    # 已有 config.yml，修复常见配置错误
    if grep -q 'localhost:8080' "${SHELL_DIR}/config.yml" 2>/dev/null; then
        sed -i 's|gitlab_url: http://localhost:8080|gitlab_url: http://127.0.0.1:3000|' "${SHELL_DIR}/config.yml"
        info "  ✓ gitlab-shell gitlab_url: 8080 → 3000"
    fi
fi

# 检查 GitLab Workhorse
[ -f "${WORKHORSE_DIR}/gitlab-workhorse" ] && info "  ✓ workhorse: ${WORKHORSE_DIR}" \
    || { warn "  ✗ workhorse 未编译: ${WORKHORSE_DIR}"; FAILED=1; }

# 检查 PostgreSQL 运行
export PATH="/usr/pgsql-18/bin:/usr/pgsql-17/bin:/usr/pgsql-16/bin:/usr/local/ruby/bin:${PATH}"

if ${REMOTE}; then
    # 远程模式：TCP 连接检测
    if PGPASSWORD="${PG_PASSWORD}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -tAc 'SELECT 1' &>/dev/null; then
        info "  ✓ PostgreSQL 远程连接正常 (${PG_HOST}:${PG_PORT})"
    elif command -v pg_isready &>/dev/null && pg_isready -h "${PG_HOST}" -p "${PG_PORT}" &>/dev/null; then
        info "  ✓ PostgreSQL 远程可达 (${PG_HOST}:${PG_PORT})"
    else
        warn "  ✗ PostgreSQL 远程不可达 (${PG_HOST}:${PG_PORT})"; FAILED=1
    fi
else
    if systemctl is-active postgresql &>/dev/null; then
        info "  ✓ PostgreSQL 运行中"
    elif pg_isready &>/dev/null; then
        info "  ✓ PostgreSQL 运行中"
    else
        warn "  ✗ PostgreSQL 未运行，请先: systemctl start postgresql"; FAILED=1
    fi
fi

# 检查 btree_gist 扩展（GitLab schema 需要）
if ${REMOTE}; then
    # 远程模式：通过 psql 检测扩展是否可用
    if PGPASSWORD="${PG_PASSWORD}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -tAc "SELECT 1 FROM pg_available_extensions WHERE name='btree_gist'" 2>/dev/null | grep -q 1; then
        info "  ✓ btree_gist 扩展可用（远程）"
    else
        warn "  ✗ btree_gist 扩展缺失，请在 PG 服务器 (${PG_HOST}) 上安装 postgresql-contrib"; FAILED=1
    fi
else
    PG_LIBDIR=$(pg_config --pkglibdir 2>/dev/null || ls -d /usr/pgsql-*/lib 2>/dev/null | head -1 || echo "/usr/pgsql-17/lib")
    if [ -f "${PG_LIBDIR}/btree_gist.so" ]; then
        info "  ✓ btree_gist 扩展可用"
    else
        warn "  ✗ btree_gist.so 缺失，尝试安装 postgresql18-contrib..."
        PG_MAJOR_VER=$(psql --version 2>&1 | awk '{print $3}' | cut -d. -f1)
        dnf install -y "postgresql${PG_MAJOR_VER}-contrib" 2>/dev/null \
            || rpm -ivh "https://download.postgresql.org/pub/repos/yum/${PG_MAJOR_VER}/redhat/rhel-9-x86_64/postgresql${PG_MAJOR_VER}-contrib-${PG_MAJOR_VER}.4-1PGDG.rhel9.x86_64.rpm" 2>/dev/null \
            || warn "  ✗ 自动安装失败，请手动安装 postgresql${PG_MAJOR_VER}-contrib"
        [ -f "${PG_LIBDIR}/btree_gist.so" ] && info "  ✓ btree_gist 扩展已修复" || FAILED=1
    fi
fi

# 检查 Redis 运行
if ${REMOTE}; then
    # 远程模式：TCP 连接检测
    redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" --no-auth-warning ping 2>/dev/null | grep -q PONG \
        && info "  ✓ Redis 远程连接正常 (${REDIS_HOST}:${REDIS_PORT})" \
        || { warn "  ✗ Redis 远程不可达 (${REDIS_HOST}:${REDIS_PORT})"; FAILED=1; }
else
    systemctl is-active redis &>/dev/null && info "  ✓ Redis 运行中" \
        || { warn "  ✗ Redis 未运行，请先: systemctl start redis"; FAILED=1; }
fi

# 检查 Ruby 可用
sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bash -c 'ruby --version' &>/dev/null && info "  ✓ Ruby 可用" \
    || { warn "  ✗ Ruby 不可用"; FAILED=1; }

# 检查 Node/Yarn 可用
command -v yarn &>/dev/null && info "  ✓ Yarn 可用" \
    || { warn "  ✗ Yarn 不可用，请先执行 build_gitlab_source.sh"; FAILED=1; }

[ $FAILED -eq 1 ] && err "依赖检查未通过，请修复后重试"

# ── psql 命令封装（本地用 Unix socket，远程用 TCP）──
_pg_sql() {
    if ${REMOTE}; then
        PGPASSWORD="${PG_PASSWORD}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" "$@"
    else
        su - postgres -c "psql \"\$@\" " _ "$@"
    fi
}

# ═══════════════════════════════════════════════
# 1. 数据库初始化
# ═══════════════════════════════════════════════
step "[1/7] 数据库初始化..."

# 检查数据库是否已存在
DB_EXISTS=$(_pg_sql -tAc "SELECT 1 FROM pg_database WHERE datname='gitlabhq_production'" 2>/dev/null || echo "0")
if [ "${DB_EXISTS}" = "1" ]; then
    info "  ✓ 数据库 gitlabhq_production 已存在，跳过初始化"
else
    info "  创建 git 用户和数据库..."
    _pg_sql -d template1 -c "CREATE USER git CREATEDB;" 2>/dev/null || true
    _pg_sql -d template1 -c "ALTER USER git WITH PASSWORD '${PG_PASSWORD}';" 2>/dev/null || true

    # 扩展（官方要求 pg_trgm + btree_gist + plpgsql）
    _pg_sql -d template1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" 2>/dev/null || true
    _pg_sql -d template1 -c "CREATE EXTENSION IF NOT EXISTS btree_gist;" 2>/dev/null || true
    _pg_sql -d template1 -c "CREATE EXTENSION IF NOT EXISTS plpgsql;" 2>/dev/null || true

    # 创建数据库
    _pg_sql -d template1 -c "CREATE DATABASE gitlabhq_production OWNER git;" 2>/dev/null || true

    # 验证
    DB_EXISTS=$(_pg_sql -tAc "SELECT 1 FROM pg_database WHERE datname='gitlabhq_production'" 2>/dev/null || echo "0")
    [ "${DB_EXISTS}" = "1" ] && info "  ✓ 数据库创建成功" || err "数据库创建失败"
fi

# ═══════════════════════════════════════════════
# 2. 初始化 GitLab（rake gitlab:setup）
# ═══════════════════════════════════════════════
step "[2/7] 初始化 GitLab（DB schema + seed）..."

cd "${GITLAB_DIR}"

# 确保 Redis 配置文件存在且密码正确（@ 需 URL 编码为 %40）
if [ ! -f config/resque.yml ] || ! grep -q "${REDIS_HOST}:${REDIS_PORT}" config/resque.yml 2>/dev/null; then
    info "  生成 resque.yml..."
    cat > config/resque.yml << RESQUEEOF
development:
  url: redis://localhost:6379
test:
  url: redis://localhost:6379
production:
  url: redis://:${_REDIS_PW_ENCODED}@${REDIS_HOST}:${REDIS_PORT}
RESQUEEOF
    chown git:git config/resque.yml
    info "  ✓ resque.yml 已创建"
fi
if [ ! -f config/cable.yml ] || ! grep -q "${REDIS_HOST}:${REDIS_PORT}" config/cable.yml 2>/dev/null; then
    info "  生成 cable.yml..."
    cat > config/cable.yml << CABLEEOF
development:
  adapter: redis
  url: redis://localhost:6379
test:
  adapter: redis
  url: redis://localhost:6379
production:
  adapter: redis
  url: redis://:${_REDIS_PW_ENCODED}@${REDIS_HOST}:${REDIS_PORT}
CABLEEOF
    chown git:git config/cable.yml
    info "  ✓ cable.yml 已创建"
fi

# ── Gitaly 初始化（无论 schema 是否已存在，都必须生成 config.toml）──
# 生成 .gitlab_shell_secret（首次运行时缺失）
if [ ! -f "${GITLAB_DIR}/.gitlab_shell_secret" ]; then
    cat > "${GITLAB_DIR}/.gitlab_shell_secret" << SECEOF
default: $(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
gitaly_token: $(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
SECEOF
    chown git:git "${GITLAB_DIR}/.gitlab_shell_secret"
    chmod 600 "${GITLAB_DIR}/.gitlab_shell_secret"
    info "  ✓ .gitlab_shell_secret 已生成"
fi
_gitaly_token=$(grep -oP 'gitaly_token:\s*\K.*' "${GITLAB_DIR}/.gitlab_shell_secret" 2>/dev/null || head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)

mkdir -p /home/git/repositories
chown git:git /home/git/repositories
mkdir -p "${GITLAB_DIR}/tmp/sockets/private"
chown -R git:git "${GITLAB_DIR}/tmp"

# 生成 Gitaly config.toml（无条件，每次安装都确保存在）
if [ ! -f "${GITALY_DIR}/config.toml" ]; then
    info "  生成 Gitaly config.toml..."
    _gitlab_url_path=$(echo "${GITLAB_DIR}" | sed 's|/|%2F|g')
    cat > "${GITALY_DIR}/config.toml" << GITALYCONF
socket_path = '${GITLAB_DIR}/tmp/sockets/private/gitaly.socket'
bin_dir = '${GITALY_DIR}/_build/bin'

[gitlab]
url = 'http+unix://${_gitlab_url_path}%2Ftmp%2Fsockets%2Fgitlab-workhorse.socket'

[[storage]]
name = 'default'
path = '/home/git/repositories'

[auth]
token = '${_gitaly_token}'

[logging]
format = 'json'
GITALYCONF
    chown git:git "${GITALY_DIR}/config.toml"
    chmod 640 "${GITALY_DIR}/config.toml"
    info "  ✓ config.toml 已生成: ${GITALY_DIR}/config.toml"
fi

# 同步 gitlab.yml 的 gitaly 配置
if grep -q 'gitaly_address:' "${GITLAB_DIR}/config/gitlab.yml" 2>/dev/null; then
    sudo -u git -H sed -i "s|gitaly_address:.*|gitaly_address: unix:${GITLAB_DIR}/tmp/sockets/private/gitaly.socket|" "${GITLAB_DIR}/config/gitlab.yml"
fi
# 同步 gitlab.yml gitaly token（生产环境，第一个 gitaly: 块）
if grep -q 'gitaly:' "${GITLAB_DIR}/config/gitlab.yml" 2>/dev/null; then
    sudo -u git -H awk -v t="${_gitaly_token}" '
        /^  gitaly:/ && !done { found=1 }
        found && /token:/ { sub(/token:.*/, "token: \x27" t "\x27"); found=0; done=1 }
        { print }
    ' "${GITLAB_DIR}/config/gitlab.yml" > /tmp/gitlab.yml.tmp \
        && mv /tmp/gitlab.yml.tmp "${GITLAB_DIR}/config/gitlab.yml"
    chown git:git "${GITLAB_DIR}/config/gitlab.yml"
fi

# 重置 Gitaly 元数据（防止 token 变更后 hmac 签名错误）
if [ -f /home/git/repositories/.gitaly-metadata ]; then
    _CUR_GITALY_TOKEN=$(grep -oP "token\s*=\s*'\K[^']+" "${GITALY_DIR}/config.toml" 2>/dev/null || echo "")
    _CUR_META_HMAC=$(grep -oP '"hmac_secret":"\K[^"]+' /home/git/repositories/.gitaly-metadata 2>/dev/null || echo "")
    if [ -n "${_CUR_GITALY_TOKEN}" ] && [ "${_CUR_META_HMAC}" != "${_CUR_GITALY_TOKEN}" ]; then
        rm -f /home/git/repositories/.gitaly-metadata
        info "  ✓ Gitaly 元数据已重置（token 已更新）"
    fi
fi

# ── 检查是否已初始化 ──
SCHEMA_DONE=$(_pg_sql -d gitlabhq_production -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='schema_migrations'" 2>/dev/null || echo "0")
if [ "${SCHEMA_DONE}" = "1" ]; then
    ROWS=$(_pg_sql -d gitlabhq_production -tAc "SELECT count(*) FROM schema_migrations" 2>/dev/null || echo "0")
    info "  ✓ schema_migrations 已存在 (${ROWS} migrations)，跳过 rake gitlab:setup"
else
    # 先确保 Gitaly 在运行（rake gitlab:setup 需要）
    if ! systemctl is-active gitlab-gitaly &>/dev/null; then
        info "  先启动 Gitaly（rake gitlab:setup 需要）..."
        # gitlab.target 必须存在，否则 systemctl enable 报依赖错误
        if [ ! -f /etc/systemd/system/gitlab.target ]; then
            cat > /etc/systemd/system/gitlab.target << 'TARGETEOF'
[Unit]
Description=GitLab - self-hosted git management system
TARGETEOF
            systemctl daemon-reload
        fi
        if [ -f "${GITLAB_DIR}/lib/support/systemd/gitlab-gitaly.service" ]; then
            cp "${GITLAB_DIR}/lib/support/systemd/gitlab-gitaly.service" /etc/systemd/system/
            systemctl daemon-reload
            systemctl enable gitlab-gitaly 2>/dev/null || true
            systemctl start gitlab-gitaly
            sleep 3
            systemctl is-active gitlab-gitaly &>/dev/null && info "  ✓ Gitaly 已启动" || warn "Gitaly systemd 启动失败，尝试手动启动..."
        fi
        # 兜底：systemd 启动失败则手动后台运行
        if ! systemctl is-active gitlab-gitaly &>/dev/null; then
            sudo -u git -H bash -c "cd ${GITALY_DIR} && ./_build/bin/gitaly serve ${GITALY_DIR}/config.toml &>/tmp/gitaly.log &"
            sleep 3
            info "  Gitaly 手动后台启动"
        fi

        # 等待 Gitaly socket 就绪
        info "  等待 Gitaly socket 就绪..."
        for i in $(seq 1 30); do
            if [ -S "${GITLAB_DIR}/tmp/sockets/private/gitaly.socket" ]; then
                info "  ✓ Gitaly socket 就绪 (${i}s)"
                sleep 2  # 给 Gitaly 额外的初始化时间
                break
            fi
            [ $i -eq 30 ] && warn "  Gitaly socket 超时 (30s)，检查: /tmp/gitaly.log"
            sleep 1
        done
    fi

    info "  执行 rake gitlab:setup（创建表结构 + 种子数据）..."
	# 远程模式：更新 database.yml 指向远程 PG
	if ${REMOTE}; then
	    info "  配置 database.yml → ${PG_HOST}:${PG_PORT}"
	    sudo -u git -H sed -i "s|host: 127.0.0.1|host: ${PG_HOST}|g" "${GITLAB_DIR}/config/database.yml"
	    # 确保 port 字段存在
	    if ! grep -q 'port:' "${GITLAB_DIR}/config/database.yml" 2>/dev/null; then
	        sudo -u git -H sed -i "s|host: ${PG_HOST}|host: ${PG_HOST}\n    port: ${PG_PORT}|" "${GITLAB_DIR}/config/database.yml"
	    else
	        sudo -u git -H sed -i "s|port: .*|port: ${PG_PORT}|g" "${GITLAB_DIR}/config/database.yml"
	    fi
	    info "  ✓ database.yml 已更新"
	fi

    info "  （此步骤需要 2-5 分钟，请耐心等待）"
    info "  日志: /tmp/rake_setup.log"
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rake gitlab:setup RAILS_ENV=production force=yes --trace 2>&1 | tee /tmp/rake_setup.log \
        || { warn "  完整日志: /tmp/rake_setup.log"; tail -80 /tmp/rake_setup.log; err "rake gitlab:setup 失败，详见 /tmp/rake_setup.log"; }

    info "  ✓ GitLab 初始化完成"
fi

# ═══════════════════════════════════════════════
# 3. 编译前端资源
# ═══════════════════════════════════════════════
step "[3/7] 编译前端资源..."

# webpack 编译峰值需 5-6 GB 内存，先停掉 Puma/Sidekiq 释放 ~4 GB
info "  编译前暂停 Puma / Sidekiq / Workhorse 释放内存..."
systemctl stop gitlab-puma gitlab-sidekiq gitlab-workhorse 2>/dev/null || true
sleep 2
_tmp_services_stopped=true

cd "${GITLAB_DIR}"

# Yarn 安装
if [ -d "node_modules" ] && [ "$(ls node_modules/.package-lock.json 2>/dev/null)" != "" ]; then
    NODE_MODULES_COUNT=$(find node_modules -maxdepth 1 -type d | wc -l)
    if [ "${NODE_MODULES_COUNT}" -gt 50 ]; then
        info "  ✓ node_modules 已存在 (${NODE_MODULES_COUNT} packages)，跳过 yarn install"
    else
        info "  node_modules 不完整，重新安装..."
        rm -rf node_modules
    fi
fi

if [ ! -d "node_modules" ] || [ "$(find node_modules -maxdepth 1 -type d | wc -l)" -lt 50 ]; then
    # 为 git 用户配置 npm/yarn 国内镜像
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" npm config set registry https://registry.npmmirror.com 2>/dev/null || true
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" yarn config set registry https://registry.npmmirror.com 2>/dev/null || true

    # yarn.lock 中所有包 URL 都硬编码指向 registry.yarnpkg.com（忽略 registry 配置）
    # 替换为华为云镜像（672KB/s，包含 @gitlab 包），全量替换无需区分 scope
    info "  yarn.lock URL 替换为华为云镜像..."
    sed -i 's|registry.yarnpkg.com|mirrors.huaweicloud.com/repository/npm|g' yarn.lock
    info "  ✓ yarn.lock 已替换"

    info "  yarn install --production --ignore-engines..."
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" yarn install --production --ignore-engines  \
        || { warn "yarn install 失败，尝试不带 --ignore-engines..."; sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" yarn install --production --ignore-engines --network-concurrency 4 ; }
    info "  ✓ Node 依赖安装完成"
fi

# 前端资源编译（自适应 Node 堆内存 + 区分 CRLF/OOM 错误）
# 成功标志：webpack 编译完成会生成 manifest.json，同时写入标记文件
_WEBPACK_DONE_MARKER="${GITLAB_DIR}/tmp/.webpack_compile_done"
if [ -f "${_WEBPACK_DONE_MARKER}" ] && [ -f "public/assets/webpack/manifest.json" ]; then
    info "  ✓ 前端资源已编译，跳过 assets:compile"
else
    # 清除上次不完整的编译残留（没标志 = 没成功过）
    if [ -d "public/assets" ]; then
        info "  未检测到编译完成标志，清除上次残留..."
        rm -rf public/assets
    fi
    rm -f "${_WEBPACK_DONE_MARKER}"

    # ── 自适应内存计算（控制 worker 并行数 + 堆大小防止 OOM）──
    # OOM 根因: terser-webpack-plugin 默认并行度 = CPU 核数 - 1，
    #   每个 worker 是独立 fork 子进程，继承 NODE_OPTIONS --max-old-space-size，
    #   5 worker × 7GB = 35GB 虚拟地址空间 → OOM Killer (total-vm 超限)
    # 方案: (1) 通过 --require 注入脚本限制 os.cpus() → 减少并行 worker 数
    #       (2) 按公式分配每进程 V8 堆 → 堆 × 进程数 ≤ 60% 虚拟内存
    # 可通过环境变量覆盖: NODE_HEAP_MB=2048 WEBPACK_PARALLEL=2 bash ...
    if [ -n "${NODE_HEAP_MB:-}" ]; then
        _NODE_HEAP="${NODE_HEAP_MB}"
        info "  使用手动指定的 Node 堆: ${_NODE_HEAP}MB"
    fi
    if [ -n "${WEBPACK_PARALLEL:-}" ]; then
        _WEBPACK_PARALLEL="${WEBPACK_PARALLEL}"
        info "  使用手动指定的 webpack 并行度: ${_WEBPACK_PARALLEL}"
    fi

    # 自动计算（未手动指定时）
    if [ -z "${_NODE_HEAP:-}" ] || [ -z "${_WEBPACK_PARALLEL:-}" ]; then
        _MEM_TOTAL_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)
        _SWAP_TOTAL=$(awk '/SwapTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
        _VIRT_GB=$((_MEM_TOTAL_GB + _SWAP_TOTAL))
        _CPU_COUNT=$(nproc 2>/dev/null || echo 4)
        info "  物理: ${_MEM_TOTAL_GB}GB, Swap: ${_SWAP_TOTAL}GB, 虚拟: ${_VIRT_GB}GB, CPU: ${_CPU_COUNT}"

        # 虚拟内存 < 16GB 时自动创建/扩容 swap（webpack 主进程实测需 ≥4GB 堆）
        if [ "${_VIRT_GB}" -lt 16 ]; then
            _SWAP_TARGET=16
            _SWAP_NEEDED=$(( (_SWAP_TARGET - _VIRT_GB) * 1024 ))
            _SWAP_FILE="/swapfile"
            warn "  虚拟内存 ${_VIRT_GB}GB < ${_SWAP_TARGET}GB，创建 ${_SWAP_NEEDED}MB swap..."
            if swapon --show 2>/dev/null | grep -q "${_SWAP_FILE}"; then
                # 已有 swap 但总量不够，尝试扩展现有 swap 或追加
                _CUR_SWAP_MB=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
                if [ "${_CUR_SWAP_MB}" -lt "$(( (_SWAP_TARGET - _MEM_TOTAL_GB) * 1024 ))" ]; then
                    swapoff "${_SWAP_FILE}" 2>/dev/null || true
                    rm -f "${_SWAP_FILE}"
                    dd if=/dev/zero of="${_SWAP_FILE}" bs=1M count="$(( (_SWAP_TARGET - _MEM_TOTAL_GB) * 1024 ))" 2>/dev/null || true
                    chmod 600 "${_SWAP_FILE}"
                    mkswap "${_SWAP_FILE}" 2>/dev/null && swapon "${_SWAP_FILE}" 2>/dev/null || true
                else
                    info "  ✓ swap 已充足"
                fi
            else
                [ -f "${_SWAP_FILE}" ] && { swapoff "${_SWAP_FILE}" 2>/dev/null || true; rm -f "${_SWAP_FILE}"; }
                dd if=/dev/zero of="${_SWAP_FILE}" bs=1M count="${_SWAP_NEEDED}" 2>/dev/null || true
                chmod 600 "${_SWAP_FILE}"
                mkswap "${_SWAP_FILE}" 2>/dev/null && swapon "${_SWAP_FILE}" 2>/dev/null || true
            fi
            if swapon --show 2>/dev/null | grep -q "${_SWAP_FILE}"; then
                _SWAP_TOTAL_NEW=$(awk '/SwapTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
                _VIRT_GB=$((_MEM_TOTAL_GB + _SWAP_TOTAL_NEW))
                info "  ✓ swap 就绪，虚拟: ${_VIRT_GB}GB"
                grep -q "${_SWAP_FILE}" /etc/fstab 2>/dev/null || echo "${_SWAP_FILE} none swap sw 0 0" >> /etc/fstab
            else
                warn "  ✗ swap 创建失败，当前虚拟: ${_VIRT_GB}GB"
            fi
        fi

        # ── 并行度 + 堆大小 ──
        # 实测数据（GitLab 19.x, 9GB RAM, 2 次失败）:
        #   2252MB → OOM (webpack 主进程 GC 无效)
        #   3379MB → OOM (peak live 3.3GB, 需要 ~30% GC 冗余 = 4.3GB+)
        # 结论: 主进程至少需要 4096MB 堆，推荐 4500+
        # 约束: (workers+1) × heap ≤ 80% 虚拟内存 (1w) / 70% (2w+)
        if [ -z "${_WEBPACK_PARALLEL:-}" ]; then
            # virt < 16GB 强制单 worker（多 worker 分堆后每进程不够 4GB）
            if [ "${_VIRT_GB}" -lt 16 ]; then
                _WEBPACK_PARALLEL=1
            else
                _WEBPACK_PARALLEL=$(( (_VIRT_GB - 6) / 5 + 1 ))
                [ "${_WEBPACK_PARALLEL}" -gt "${_CPU_COUNT}" ] && _WEBPACK_PARALLEL="${_CPU_COUNT}"
            fi
        fi

        if [ -z "${_NODE_HEAP:-}" ]; then
            _PROC_COUNT=$((_WEBPACK_PARALLEL + 1))
            # 单 worker: 80% 虚拟给 2 进程；多 worker: 70%
            if [ "${_WEBPACK_PARALLEL}" -eq 1 ]; then
                _NODE_HEAP=$(( _VIRT_GB * 1024 * 80 / 100 / _PROC_COUNT ))
            else
                _NODE_HEAP=$(( _VIRT_GB * 1024 * 70 / 100 / _PROC_COUNT ))
            fi
            # 循环降 worker 直到每进程堆 ≥ 4096
            while [ "${_WEBPACK_PARALLEL}" -gt 1 ] && [ "${_NODE_HEAP}" -lt 4096 ]; do
                _WEBPACK_PARALLEL=$((_WEBPACK_PARALLEL - 1))
                _PROC_COUNT=$((_WEBPACK_PARALLEL + 1))
                _NODE_HEAP=$(( _VIRT_GB * 1024 * 70 / 100 / _PROC_COUNT ))
            done
            [ "${_NODE_HEAP}" -lt 4096 ] && _NODE_HEAP=4096
            [ "${_NODE_HEAP}" -gt 5120 ] && _NODE_HEAP=5120
        fi
        info "  webpack 并行: ${_WEBPACK_PARALLEL} worker, 堆: ${_NODE_HEAP}MB/进程"
    fi

    # ── 创建 CPU 限制 preload 脚本 ──
    # terser-webpack-plugin 默认并行度 = os.cpus().length - 1
    # 通过 NODE_OPTIONS="--require <脚本>" 注入 monkey-patch，
    # 使 os.cpus() 只返回前 _WEBPACK_PARALLEL+1 个核心（+1 给主进程的 webpack orchestration）
    _CPU_LIMIT_JS="/tmp/limit_cpus_$$.js"
    _CPU_VISIBLE=$((_WEBPACK_PARALLEL + 1))
    cat > "${_CPU_LIMIT_JS}" << CPUEOF
const os = require('os');
const origCpus = os.cpus.bind(os);
const limit = ${_CPU_VISIBLE};
os.cpus = function() { return origCpus().slice(0, limit); };
CPUEOF
    chmod 644 "${_CPU_LIMIT_JS}"
    info "  CPU 可见数限制: ${_CPU_VISIBLE} (→ terser 并行 ${_WEBPACK_PARALLEL})"

    info "  编译前端资源（约 10-30 分钟，日志: /tmp/webpack_compile.log）..."

    _WEBPACK_LOG="/tmp/webpack_compile.log"
    # --require 注入 os.cpus() monkey-patch（主进程 + 所有 worker-farm 子进程均继承）
    # --max-old-space-size 限制每个 Node 进程的 V8 堆
    # 两者配合: (workers+1) × heap ≤ 60% 虚拟内存
    if sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" \
        NODE_OPTIONS="--require ${_CPU_LIMIT_JS} --max-old-space-size=${_NODE_HEAP}" \
        bundle exec rake gitlab:assets:compile RAILS_ENV=production NODE_ENV=production 2>&1 | tee "${_WEBPACK_LOG}"; then
        touch "${_WEBPACK_DONE_MARKER}"
        info "  ✓ 前端资源编译完成"
        rm -f "${_CPU_LIMIT_JS}"
    else
        rm -f "${_CPU_LIMIT_JS}"
        _TAIL_LOG=$(tail -30 "${_WEBPACK_LOG}" 2>/dev/null || true)
        if echo "${_TAIL_LOG}" | grep -q "bash.*\r\|Permission denied.*bash"; then
            warn "  日志: ${_WEBPACK_LOG}"
            err "前端资源编译失败：检测到 Windows 换行符 (CRLF) 残留"
        elif echo "${_TAIL_LOG}" | grep -q "SIGKILL\|heap out of memory\|OOM\|SIGABRT\|CALL_AND_RETRY_LAST\|EPIPE"; then
            warn "  日志: ${_WEBPACK_LOG}"
            err "前端资源编译失败：内存溢出 (heap=${_NODE_HEAP}MB, workers=${_WEBPACK_PARALLEL}, virt=${_VIRT_GB:-?}GB)
          建议: 增加内存/swap 至 16GB+ 或 NODE_HEAP_MB=2048 WEBPACK_PARALLEL=1 bash install_gitlab_source.sh"
        else
            warn "  日志: ${_WEBPACK_LOG}"
            err "前端资源编译失败，详见 ${_WEBPACK_LOG}"
        fi
    fi
fi
# 编译完成后恢复之前暂停的服务
if ${_tmp_services_stopped:-false}; then
    info "  编译完成，恢复 Puma / Sidekiq / Workhorse..."
    systemctl start gitlab-puma gitlab-sidekiq gitlab-workhorse 2>/dev/null || true
    sleep 3
fi

# ═══════════════════════════════════════════════
# 4. Systemd 服务
# ═══════════════════════════════════════════════
step "[4/7] 配置 Systemd 服务..."

cd "${GITLAB_DIR}"

SYSTEMD_SRC="lib/support/systemd"
UNIT_DIR="/etc/systemd/system"

if [ -d "${SYSTEMD_SRC}" ]; then
    SERVICE_COUNT=0
    for unit in "${SYSTEMD_SRC}"/*.service "${SYSTEMD_SRC}"/gitlab.target; do
        [ -f "${unit}" ] 2>/dev/null || continue
        unit_name=$(basename "${unit}")
        if [ ! -f "${UNIT_DIR}/${unit_name}" ]; then
            cp "${unit}" "${UNIT_DIR}/${unit_name}"
            SERVICE_COUNT=$((SERVICE_COUNT + 1))
        else
            info "  ${unit_name} 已存在"
        fi
    done
    systemctl daemon-reload
    info "  ✓ 已部署 ${SERVICE_COUNT} 个 systemd 单元"

    # ── 修正 Workhorse 配置（GitLab 19.x 兼容性）──
    # 1. authBackend 端口必须与 Puma 一致（puma.rb 默认 3000）
    # 2. authSocket 若 Puma 未创建 Unix socket 则必须移除，否则 Workhorse 优先 socket 导致 502
    _WH_SVC="${UNIT_DIR}/gitlab-workhorse.service"
    if [ -f "${_WH_SVC}" ]; then
        if grep -q 'authBackend.*8080' "${_WH_SVC}" 2>/dev/null; then
            sed -i 's|-authBackend http://127.0.0.1:8080|-authBackend http://127.0.0.1:3000|' "${_WH_SVC}"
            info "  ✓ Workhorse authBackend: 8080 → 3000"
        fi
        # 移除不存在的 authSocket，只保留 TCP
        if grep -q '\-authSocket' "${_WH_SVC}" 2>/dev/null; then
            _PUMA_SOCKET="${GITLAB_DIR}/tmp/sockets/gitlab.socket"
            if [ ! -S "${_PUMA_SOCKET}" ]; then
                sed -i 's|-authSocket [^ ]* ||' "${_WH_SVC}"
                info "  ✓ Workhorse authSocket 已移除（Puma 未创建 Unix socket）"
            fi
        fi
        systemctl daemon-reload
    fi
else
    warn "  lib/support/systemd 目录不存在，创建最小化服务文件..."

    # Gitaly
    cat > "${UNIT_DIR}/gitlab-gitaly.service" << GITALYUNIT
[Unit]
Description=GitLab Gitaly
After=network.target

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${GITALY_DIR}
Environment="HOME=${GITLAB_HOME}"
ExecStart=${GITALY_DIR}/_build/bin/gitaly ${GITALY_DIR}/config.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
GITALYUNIT

    # Puma
    cat > "${UNIT_DIR}/gitlab-puma.service" << PUMAUNIT
[Unit]
Description=GitLab Puma
After=network.target postgresql.service redis.service gitlab-gitaly.service
Requires=postgresql.service redis.service

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${GITLAB_DIR}
Environment="RAILS_ENV=production"
ExecStart=/usr/local/bin/bundle exec puma -C ${GITLAB_DIR}/config/puma.rb
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
PUMAUNIT

    # Sidekiq
    cat > "${UNIT_DIR}/gitlab-sidekiq.service" << SIDEKIQUNIT
[Unit]
Description=GitLab Sidekiq
After=network.target postgresql.service redis.service
Requires=postgresql.service redis.service

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${GITLAB_DIR}
Environment="RAILS_ENV=production"
ExecStart=/usr/local/bin/bundle exec sidekiq -C ${GITLAB_DIR}/config/sidekiq_queues.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SIDEKIQUNIT

    # Workhorse（Unix socket + Puma TCP 3000）
    cat > "${UNIT_DIR}/gitlab-workhorse.service" << WORKHORSEUNIT
[Unit]
Description=GitLab Workhorse
After=network.target gitlab-puma.service
Wants=gitlab-puma.service

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${GITLAB_DIR}
Environment="HOME=${GITLAB_HOME}"
ExecStart=${WORKHORSE_DIR}/gitlab-workhorse \\
    -listenUmask 0 \\
    -listenNetwork unix \\
    -listenAddr ${GITLAB_DIR}/tmp/sockets/gitlab-workhorse.socket \\
    -authBackend http://127.0.0.1:3000 \\
    -documentRoot ${GITLAB_DIR}/public \\
    -secretPath ${GITLAB_DIR}/.gitlab_workhorse_secret
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
WORKHORSEUNIT

    # gitlab.target
    cat > "${UNIT_DIR}/gitlab.target" << TARGETUNIT
[Unit]
Description=GitLab - Self-compiled
Wants=postgresql.service redis.service gitlab-gitaly.service gitlab-workhorse.service gitlab-puma.service gitlab-sidekiq.service
After=postgresql.service redis.service gitlab-gitaly.service gitlab-workhorse.service

[Install]
WantedBy=multi-user.target
TARGETUNIT

    systemctl daemon-reload
    info "  ✓ 已创建最小化 systemd 单元"
fi

# 日志目录
mkdir -p "${LOG_DIR}" /data/gitlab/{uploads,artifacts,pages,registry,terraform_state}
chown -R git:git "${LOG_DIR}" /data/gitlab
chmod 755 "${LOG_DIR}"

info "  ✓ Systemd 服务就绪"

# 确保 Puma 监听 TCP 端口（非仅 Unix socket）
if [ -f "${GITLAB_DIR}/config/puma.rb" ]; then
    if ! grep -q 'port 3000' "${GITLAB_DIR}/config/puma.rb" 2>/dev/null; then
        sudo -u git -H sed -i 's|bind .unix://.*|port 3000|' "${GITLAB_DIR}/config/puma.rb"
        info "  ✓ Puma 端口已设为 3000"
    fi
fi

# ═══════════════════════════════════════════════
# 5. 启动服务
# ═══════════════════════════════════════════════
step "[5/7] 启动 GitLab..."

# 按官方顺序启动: Gitaly → DB setup(已完成) → Workhorse → Puma → Sidekiq
for svc in gitlab-gitaly gitlab-workhorse gitlab-puma gitlab-sidekiq; do
    if [ -f "${UNIT_DIR}/${svc}.service" ]; then
        systemctl enable "${svc}" 2>/dev/null || true
        if systemctl is-active "${svc}" &>/dev/null; then
            info "  ${svc} 已运行"
        else
            systemctl start "${svc}" 2>&1 || warn "${svc} 启动有警告"
            sleep 2
            if systemctl is-active "${svc}" &>/dev/null; then
                info "  ✓ ${svc} 已启动"
            else
                warn "  ✗ ${svc} 启动失败，检查: journalctl -u ${svc} -n 20"
            fi
        fi
    fi
done

# 启用 gitlab.target
[ -f "${UNIT_DIR}/gitlab.target" ] && { systemctl enable gitlab.target 2>/dev/null || true; }

info "  ✓ 服务启动完成"

# ═══════════════════════════════════════════════
# 6. Nginx 反向代理
# ═══════════════════════════════════════════════
step "[6/8] Nginx 反向代理..."

NGINX_SCRIPT="${_SCRIPT_DIR}/../../nginx/install_nginx.sh"
NGINX_CONF_DIR="/usr/local/nginx/conf/conf.d"
NGINX_GITLAB_CONF="${NGINX_CONF_DIR}/gitlab.conf"

# 安装 Nginx（如果未安装）
if [ -x /usr/local/nginx/sbin/nginx ] || [ -x /usr/sbin/nginx ]; then
    info "  ✓ Nginx 已安装"
else
    info "  调用 Nginx 安装脚本..."
    if [ -f "${NGINX_SCRIPT}" ]; then
        bash "${NGINX_SCRIPT}" --port "${GITLAB_PORT}" || warn "Nginx 安装有警告，继续配置..."
    else
        warn "  Nginx 安装脚本不存在: ${NGINX_SCRIPT}"
        info "  尝试 dnf 在线安装 nginx..."
        dnf install -y nginx 2>/dev/null || true
    fi
fi

# 定位 nginx 二进制和配置目录（兼容 RPM 和 rpm2cpio 安装方式）
if [ -x /usr/local/nginx/sbin/nginx ]; then
    _NGINX_BIN=/usr/local/nginx/sbin/nginx
    NGINX_CONF_MAIN=/usr/local/nginx/conf/nginx.conf
    NGINX_CONF_DIR=/usr/local/nginx/conf/conf.d
elif [ -x /usr/sbin/nginx ]; then
    _NGINX_BIN=/usr/sbin/nginx
    NGINX_CONF_MAIN=/etc/nginx/nginx.conf
    NGINX_CONF_DIR=/etc/nginx/conf.d
else
    _NGINX_BIN=""
fi

if [ -n "${_NGINX_BIN}" ]; then
    mkdir -p "${NGINX_CONF_DIR}"
    NGINX_GITLAB_CONF="${NGINX_CONF_DIR}/gitlab.conf"

    # ── 部署 GitLab 反代配置 ──
    # 优先使用 Nginx 安装时从 pkg_deploy/nginx/conf.d/ 拷贝的模板
    # （install_nginx.sh 已将模板 *.conf 拷贝到 conf.d 并替换 {{NGINX_PORT}}）
    # 此处补全 GitLab 专用变量: {{GITLAB_DIR}}, {{GITLAB_DOMAIN}}
    _TEMPLATE_SRC="${_SCRIPT_DIR}/../../nginx/conf.d/gitlab.conf"

    if [ -f "${NGINX_GITLAB_CONF}" ] && grep -q '{{GITLAB_DIR}}' "${NGINX_GITLAB_CONF}" 2>/dev/null; then
        info "  使用模板: ${NGINX_GITLAB_CONF}（由 install_nginx.sh 部署）"
    elif [ -f "${_TEMPLATE_SRC}" ]; then
        info "  使用模板: ${_TEMPLATE_SRC}"
        cp "${_TEMPLATE_SRC}" "${NGINX_GITLAB_CONF}"
    else
        warn "  gitlab.conf 模板不存在，生成最小化配置..."
        cat > "${NGINX_GITLAB_CONF}" << 'FALLBACKEOF'
# GitLab CE 反向代理（最小化 fallback — 请替换为 pkg_deploy/nginx/conf.d/gitlab.conf 模板）
upstream gitlab-workhorse {
    server unix:{{GITLAB_DIR}}/tmp/sockets/gitlab-workhorse.socket fail_timeout=0;
}
server {
    listen {{GITLAB_PORT}};
    server_name {{GITLAB_DOMAIN}};
    root {{GITLAB_DIR}}/public;
    location /assets/ {
        gzip_static on;
        expires max;
        add_header Cache-Control public;
    }
    location /uploads/ {
        expires max;
    }
    location / {
        client_max_body_size 0;
        proxy_read_timeout 300;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://gitlab-workhorse;
    }
}
FALLBACKEOF
    fi

    # 替换 GitLab 专用占位符
    sed -i "s|{{GITLAB_DIR}}|${GITLAB_DIR}|g"   "${NGINX_GITLAB_CONF}"
    sed -i "s|{{GITLAB_DOMAIN}}|${GITLAB_DOMAIN}|g" "${NGINX_GITLAB_CONF}"
    sed -i "s|{{GITLAB_PORT}}|${GITLAB_PORT}|g"   "${NGINX_GITLAB_CONF}"

    # 检查是否还有未替换的占位符
    if grep -q '{{[A-Z_]\+}}' "${NGINX_GITLAB_CONF}" 2>/dev/null; then
        warn "  ⚠ gitlab.conf 存在未替换的占位符:"
        grep -n '{{[A-Z_]\+}}' "${NGINX_GITLAB_CONF}" 2>/dev/null || true
    fi

    # 在 Nginx 主配置中 include conf.d/*.conf（如果还没 include）
    if [ -f "${NGINX_CONF_MAIN}" ] && ! grep -q "conf\.d/\*\.conf" "${NGINX_CONF_MAIN}" 2>/dev/null; then
        if grep -q '^http {' "${NGINX_CONF_MAIN}" 2>/dev/null; then
            sed -i '/^http {/a\    include '"${NGINX_CONF_DIR}"'/*.conf;' "${NGINX_CONF_MAIN}"
        fi
    fi

    info "  ✓ gitlab.conf → ${NGINX_GITLAB_CONF}"

    # 语法检查 + 启动/重载
    if ${_NGINX_BIN} -t 2>&1; then
        if systemctl is-active nginx &>/dev/null; then
            systemctl reload nginx 2>/dev/null || systemctl restart nginx
        else
            systemctl enable nginx 2>/dev/null || true
            systemctl start nginx
        fi
        sleep 2
        if systemctl is-active nginx &>/dev/null; then
            info "  ✓ Nginx 已启动，端口 ${GITLAB_PORT}"

            # ── 修正 Nginx 权限（访问 git 用户目录下的 Unix socket）──
            # nginx 用户需要遍历 /home/git/ → gitlab/tmp/sockets/ 目录链
            # 将 nginx 加入 git 组 + 开放目录组执行权限
            if ! id nginx 2>/dev/null | grep -q 'git'; then
                usermod -a -G git nginx 2>/dev/null || true
            fi
            chmod g+x /home/git 2>/dev/null || true
            systemctl restart nginx 2>/dev/null || true
            info "  ✓ Nginx 权限已修正（git 组 + 目录遍历）"
        else
            warn "  ✗ Nginx 启动失败，检查: journalctl -u nginx -n 20"
        fi
    else
        warn "  ✗ Nginx 配置语法检查未通过，检查: ${_NGINX_BIN} -t"
    fi
else
    warn "  ✗ 未找到 nginx 二进制，跳过反向代理"
    info "  GitLab Puma 监听 127.0.0.1:3000，Workhorse socket: ${GITLAB_DIR}/tmp/sockets/gitlab-workhorse.socket"
fi

# ═══════════════════════════════════════════════
# 7. 等待就绪
# ═══════════════════════════════════════════════
step "[7/8] 等待 GitLab 就绪..."

GITLAB_URL="http://127.0.0.1:${GITLAB_PORT}"
READY=false

for i in $(seq 1 60); do
    STATUS=$(curl -sk --connect-timeout 3 -o /dev/null -w '%{http_code}' "${GITLAB_URL}/help" 2>/dev/null || echo "000")
    if [ "${STATUS}" = "200" ] || [ "${STATUS}" = "302" ]; then
        info "GitLab 就绪 (${i}/60) — HTTP ${STATUS}"
        READY=true
        break
    fi
    # 也尝试不带端口
    STATUS2=$(curl -sk --connect-timeout 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1/help" 2>/dev/null || echo "000")
    if [ "${STATUS2}" = "200" ] || [ "${STATUS2}" = "302" ]; then
        info "GitLab 就绪 (${i}/60) — HTTP ${STATUS2}"
        READY=true
        break
    fi
    [ $i -eq 60 ] && warn "超时，检查: systemctl status gitlab-*" || sleep 5
done

# ═══════════════════════════════════════════════
# 7. 验证
# ═══════════════════════════════════════════════
step "[8/8] 验证..."

# 服务状态
echo ""
echo "--- 服务状态 ---"
for svc in gitlab-gitaly gitlab-workhorse gitlab-puma gitlab-sidekiq; do
    if systemctl is-active "${svc}" &>/dev/null; then
        echo "  ✓ ${svc}: active"
    else
        echo "  ✗ ${svc}: inactive"
    fi
done

# HTTP 检查
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://127.0.0.1:${GITLAB_PORT}" 2>/dev/null || echo "000")
echo ""
echo "  HTTP: ${HTTP_CODE}"

# 设置 root 密码
if ${READY}; then
    info "  设置 root 密码..."
    cd "${GITLAB_DIR}"
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bundle exec rails runner "user = User.find_by(username:'root'); user.password='${ROOT_PASS}'; user.password_confirmation='${ROOT_PASS}'; user.save!" RAILS_ENV=production 2>/dev/null \
        && info "  ✓ root 密码已设置" \
        || info "  root 密码可能已设置，跳过"
fi

# 完成
echo ""
echo "============================================"
echo "  GitLab CE 源码安装完成"
echo ""
echo "  访问:      http://${GITLAB_DOMAIN}:${GITLAB_PORT}"
echo "  账号:      root"
echo "  密码:      ${ROOT_PASS}"
echo ""
echo "  管理命令:"
echo "    systemctl start gitlab.target     # 启动全部"
echo "    systemctl stop gitlab.target      # 停止全部"
echo "    systemctl status gitlab-gitaly    # 查看各组件状态"
echo "    journalctl -u gitlab-puma -f     # 查看 Puma 日志"
echo ""
echo "  检查: cd ${GITLAB_DIR} && sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bundle exec rake gitlab:check RAILS_ENV=production"
echo "  卸载: bash clean_gitlab.sh source --data"
echo "============================================"
