#!/bin/bash
# ============================================================
# GitLab CE — 预编译包快速部署启动
#
# 从当前目录加载已编译的 GitLab 文件，直接部署启动。
# 跳过 Ruby/Go/Node 编译和 webpack 前端编译，适用于批量部署。
#
# 用法:
#   bash start_gitlab.sh [域名/IP] [--port 80] [--pass Gitlab12345]
#   bash start_gitlab.sh 192.168.10.6
#   bash start_gitlab.sh gitlab.testops.local --port 8080 --pass MyPass123
#
# 前置条件:
#   1. PostgreSQL + Redis 已安装运行（或指定远程连接）
#   2. gitlab_pkg/ 目录已准备好编译产物
# ============================================================
set -euo pipefail

# ── 配置 ──
GITLAB_DOMAIN="${1:-gitlab.testops.local}"
GITLAB_PORT="${GITLAB_PORT:-80}"
ROOT_PASS="${GITLAB_ROOT_PASSWORD:-Gitlab12345}"
GITLAB_HOME="${GITLAB_HOME:-/home/git}"
GITLAB_DIR="${GITLAB_HOME}/gitlab"
GITALY_DIR="${GITLAB_HOME}/gitaly"
SHELL_DIR="${GITLAB_HOME}/gitlab-shell"
WORKHORSE_DIR="${GITLAB_HOME}/gitlab-workhorse"
PAGES_DIR="${GITLAB_HOME}/gitlab-pages"
LOG_DIR="${LOG_DIR:-/var/log/gitlab}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) GITLAB_PORT="$2"; shift 2 ;;
        --pass) ROOT_PASS="$2"; shift 2 ;;
        *) shift ;;
    esac
done

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
_PKG_DIR="${_SCRIPT_DIR}"   # 脚本在包目录内，同目录即源包

# 加载远程配置（可选，放包目录下）
if [ -f "${_SCRIPT_DIR}/gitlab_remote.conf" ]; then
    source "${_SCRIPT_DIR}/gitlab_remote.conf"
fi
REMOTE="${REMOTE:-false}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-Pg1@zendao2024}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-Pg1@zendao2024}"
_REDIS_PW_ENCODED="${REDIS_PASSWORD//@/%40}"

# ── UI ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

[ "$(id -u)" -eq 0 ] || err "需要 root 权限"

echo "============================================"
echo "  GitLab CE 预编译包部署"
echo "  域名:      ${GITLAB_DOMAIN}"
echo "  端口:      ${GITLAB_PORT}"
echo "  包目录:    ${_PKG_DIR}"
echo "============================================"

# ═══════════════════════════════════════════════
# 0. 预编译包完整性检查
# ═══════════════════════════════════════════════
step "[0/8] 检查预编译包..."

[ -d "${_PKG_DIR}" ] || err "预编译包目录不存在: ${_PKG_DIR}"

# ── 自动解压 gitlab_pkg.tar.xz（如果存在压缩包但目录未解压）──
_PKG_TAR="${_PKG_DIR}/gitlab_pkg.tar.xz"
if [ -f "${_PKG_TAR}" ] && [ ! -d "${_PKG_DIR}/gitlab" ]; then
    info "  检测到 ${_PKG_TAR}，自动解压..."
    tar -xJf "${_PKG_TAR}" -C "${_PKG_DIR}/" 2>&1 || err "解压失败: ${_PKG_TAR}"
    info "  ✓ 解压完成"
elif [ -f "${_PKG_TAR}" ] && [ -d "${_PKG_DIR}/gitlab" ]; then
    info "  ✓ 已解压，跳过"
fi

MISSING=0
check_pkg_dir() {
    local dir="$1" desc="$2"
    if [ -d "${_PKG_DIR}/${dir}" ]; then
        local size=$(du -sh "${_PKG_DIR}/${dir}" 2>/dev/null | cut -f1)
        info "  ✓ ${dir} (${size})"
    else
        warn "  ✗ ${dir} — ${desc}"
        MISSING=$((MISSING + 1))
    fi
}
check_pkg_dir "gitlab"          "GitLab 源码 + vendor/bundle + node_modules + public/assets"
check_pkg_dir "gitaly"          "Gitaly 编译产物"
check_pkg_dir "gitlab-shell"    "GitLab Shell"
check_pkg_dir "gitlab-workhorse" "GitLab Workhorse"

[ "${MISSING}" -gt 0 ] && err "预编译包缺失 ${MISSING} 个组件，请先执行 build_gitlab_source.sh + install_gitlab_source.sh 编译"

# ═══════════════════════════════════════════════
# 1. 环境检查
# ═══════════════════════════════════════════════
step "[1/8] 环境检查..."

# git 用户
id git &>/dev/null || useradd -r -m -d "${GITLAB_HOME}" -s /bin/bash -c 'GitLab' git
info "  ✓ git 用户"

# Ruby
if [ -x /usr/local/ruby/bin/ruby ]; then
    info "  ✓ Ruby $(/usr/local/ruby/bin/ruby --version 2>&1 | head -1)"
elif command -v ruby &>/dev/null; then
    info "  ✓ Ruby $(ruby --version 2>&1 | head -1)"
    # 创建软链兼容
    [ -d /usr/local/ruby/bin ] || { mkdir -p /usr/local/ruby/bin; ln -sf "$(which ruby)" /usr/local/ruby/bin/ruby; }
else
    warn "  Ruby 未安装，将从 gitlab_pkg 中加载"
    if [ -d "${_PKG_DIR}/ruby" ]; then
        cp -a "${_PKG_DIR}/ruby" /usr/local/ruby
        ln -sf /usr/local/ruby/bin/* /usr/local/bin/
        info "  ✓ Ruby 已从包中部署"
    fi
fi

# Go
if [ -x /usr/local/go/bin/go ]; then
    info "  ✓ Go $(/usr/local/go/bin/go version 2>&1 | head -1)"
else
    if [ -d "${_PKG_DIR}/go" ]; then
        cp -a "${_PKG_DIR}/go" /usr/local/go
        ln -sf /usr/local/go/bin/* /usr/local/bin/
        info "  ✓ Go 已从包中部署"
    fi
fi

# Node.js（非必须，前端已预编译，仅 rake 任务可能需要）
if command -v node &>/dev/null; then
    info "  ✓ Node $(node --version 2>&1)"
else
    warn "  Node 未安装（非必须，前端资源已预编译）"
fi

# ── 运行时最终检查 ──
if [ ! -x /usr/local/ruby/bin/ruby ] && [ ! -d "${_PKG_DIR}/ruby" ]; then
    err "Ruby 未安装且包中无 ruby/，请先执行 build_gitlab_source.sh"
fi
if [ ! -x /usr/local/go/bin/go ] && [ ! -d "${_PKG_DIR}/go" ]; then
    warn "Go 未安装（非必须，Gitaly 已预编译）"
fi

# PostgreSQL
export PATH="/usr/pgsql-18/bin:/usr/pgsql-17/bin:/usr/pgsql-16/bin:${PATH}"
if ${REMOTE}; then
    PGPASSWORD="${PG_PASSWORD}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -tAc 'SELECT 1' &>/dev/null \
        && info "  ✓ PostgreSQL 远程 (${PG_HOST}:${PG_PORT})" \
        || err "PostgreSQL 远程不可达 (${PG_HOST}:${PG_PORT})"
else
    systemctl is-active postgresql &>/dev/null && info "  ✓ PostgreSQL 运行中" \
        || err "PostgreSQL 未运行，请先: systemctl start postgresql"
fi

# Redis
if ${REMOTE}; then
    redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" --no-auth-warning ping 2>/dev/null | grep -q PONG \
        && info "  ✓ Redis 远程 (${REDIS_HOST}:${REDIS_PORT})" \
        || err "Redis 远程不可达"
else
    systemctl is-active redis &>/dev/null && info "  ✓ Redis 运行中" \
        || err "Redis 未运行，请先: systemctl start redis"
fi

# ── PG 必需扩展检查 ──
_PG_EXT_OK=true
for _ext in pg_trgm btree_gist plpgsql; do
    _HAS=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_available_extensions WHERE name='${_ext}'\"" 2>/dev/null || echo "0")
    [ "${_HAS}" = "1" ] || { warn "  ✗ PG 扩展缺失: ${_ext} (dnf install postgresql18-contrib)"; _PG_EXT_OK=false; }
done
${_PG_EXT_OK} && info "  ✓ PG 扩展 (pg_trgm, btree_gist, plpgsql)"
if ! ${_PG_EXT_OK}; then
    warn "  尝试自动安装 contrib..."
    dnf install -y postgresql18-contrib 2>/dev/null || true
fi

# ═══════════════════════════════════════════════
# 2. 部署编译产物
# ═══════════════════════════════════════════════
step "[2/8] 部署编译产物到 ${GITLAB_HOME}..."

_deploy_dir() {
    local src="${_PKG_DIR}/$1" dst="$2" label="$3"
    if [ -d "${src}" ]; then
        info "  部署 ${label}: ${src} → ${dst}"
        rm -rf "${dst}" 2>/dev/null || true
        cp -a "${src}" "${dst}"
        chown -R git:git "${dst}"
    fi
}

_deploy_dir "gitlab"          "${GITLAB_DIR}"    "GitLab"
_deploy_dir "gitaly"          "${GITALY_DIR}"     "Gitaly"
_deploy_dir "gitlab-shell"    "${SHELL_DIR}"      "GitLab Shell"
_deploy_dir "gitlab-workhorse" "${WORKHORSE_DIR}" "Workhorse"
_deploy_dir "gitlab-pages"    "${PAGES_DIR}"      "Pages"

# 确保必要目录存在
sudo -u git -H mkdir -p "${GITLAB_DIR}/tmp/pids" "${GITLAB_DIR}/tmp/sockets/private" "${GITLAB_DIR}/log"
sudo -u git -H mkdir -p "${GITLAB_HOME}/.ssh" "${GITLAB_HOME}/repositories"
chmod 700 "${GITLAB_HOME}/.ssh"

info "  ✓ 编译产物部署完成"

# ── 生成 gitlab-shell config.yml（SSH clone 必需）──
if [ -f "${SHELL_DIR}/config.yml.example" ] && [ ! -f "${SHELL_DIR}/config.yml" ]; then
    sed 's|gitlab_url: http://localhost:8080|gitlab_url: http://127.0.0.1:3000|' "${SHELL_DIR}/config.yml.example" > "${SHELL_DIR}/config.yml"
    sed -i 's|secret_file: .*|secret_file: '"${GITLAB_DIR}"'/.gitlab_shell_secret|' "${SHELL_DIR}/config.yml"
    chown git:git "${SHELL_DIR}/config.yml"
    chmod 640 "${SHELL_DIR}/config.yml"
    chown -R git:git "${SHELL_DIR}/bin/" 2>/dev/null || true
    info "  ✓ gitlab-shell config.yml 已生成"
elif [ -f "${SHELL_DIR}/config.yml" ]; then
    if grep -q 'localhost:8080' "${SHELL_DIR}/config.yml" 2>/dev/null; then
        sed -i 's|gitlab_url: http://localhost:8080|gitlab_url: http://127.0.0.1:3000|' "${SHELL_DIR}/config.yml"
        info "  ✓ gitlab-shell gitlab_url: 8080 → 3000"
    fi
fi

# ═══════════════════════════════════════════════
# 3. 配置 GitLab
# ═══════════════════════════════════════════════
step "[3/8] 配置 GitLab..."

cd "${GITLAB_DIR}"

# gitlab.yml
if [ ! -f config/gitlab.yml ] || [ ! -s config/gitlab.yml ]; then
    sudo -u git -H cp config/gitlab.yml.example config/gitlab.yml 2>/dev/null || true
    sudo -u git -H sed -i "s|host: localhost|host: $(hostname -I | awk '{print $1}')|" config/gitlab.yml 2>/dev/null || true
fi

# database.yml
if [ ! -f config/database.yml ] || [ ! -s config/database.yml ]; then
    [ -f config/database.yml.postgresql ] && sudo -u git -H cp config/database.yml.postgresql config/database.yml
    sudo -u git -H sed -i "s|username: git|username: ${PG_USER}|" config/database.yml 2>/dev/null || true
    sudo -u git -H sed -i "s|password:.*|password: ${PG_PASSWORD}|" config/database.yml 2>/dev/null || true
    sudo -u git -H sed -i "s|host:.*|host: ${PG_HOST}|" config/database.yml 2>/dev/null || true
    # 清理不支持的配置项
    sudo -u git -H /usr/local/ruby/bin/ruby -ryaml -e "
      db = YAML.load_file('config/database.yml')
      db.each_value { |env| %w[geo embedding].each { |k| env.delete(k) } if env.is_a?(Hash) }
      File.write('config/database.yml', db.to_yaml)
    " 2>/dev/null || true
fi

# 其他配置
sudo -u git -H cp config/resque.yml.example config/resque.yml 2>/dev/null || true
sudo -u git -H cp config/cable.yml.example config/cable.yml 2>/dev/null || true
sudo -u git -H cp config/secrets.yml.example config/secrets.yml 2>/dev/null || true
sudo -u git -H chmod 0600 config/secrets.yml 2>/dev/null || true

# .gitlab_shell_secret
if [ ! -f .gitlab_shell_secret ]; then
    echo "default: $(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)" > .gitlab_shell_secret
    echo "gitaly_token: $(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)" >> .gitlab_shell_secret
    chown git:git .gitlab_shell_secret
    chmod 600 .gitlab_shell_secret
fi
_gitaly_token=$(grep -oP 'gitaly_token:\s*\K.*' .gitlab_shell_secret 2>/dev/null || head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)

# Gitaly config
if [ ! -f "${GITALY_DIR}/config.toml" ]; then
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
fi

# 同步 gitlab.yml gitaly token（生产环境，第一个 gitaly: 块）
_gitaly_token_final=$(grep -oP "token\s*=\s*'\K[^']+" "${GITALY_DIR}/config.toml" 2>/dev/null || echo "${_gitaly_token}")
if grep -q 'gitaly:' "${GITLAB_DIR}/config/gitlab.yml" 2>/dev/null; then
    sudo -u git -H awk -v t="${_gitaly_token_final}" '
        /^  gitaly:/ && !done { found=1 }
        found && /token:/ { sub(/token:.*/, "token: \x27" t "\x27"); found=0; done=1 }
        { print }
    ' "${GITLAB_DIR}/config/gitlab.yml" > /tmp/gitlab.yml.tmp \
        && mv /tmp/gitlab.yml.tmp "${GITLAB_DIR}/config/gitlab.yml"
    chown git:git "${GITLAB_DIR}/config/gitlab.yml"
fi

# 重置 Gitaly 元数据（防止 token 变更后 hmac 签名错误）
if [ -f /home/git/repositories/.gitaly-metadata ]; then
    rm -f /home/git/repositories/.gitaly-metadata
    info "  ✓ Gitaly 元数据已重置（确保 token 一致）"
fi

# Resque + Cable Redis 配置
sudo -u git -H sed -i "s|url:.*|url: redis://:${_REDIS_PW_ENCODED}@${REDIS_HOST}:${REDIS_PORT}|" config/resque.yml 2>/dev/null || true
sudo -u git -H sed -i "s|url:.*|url: redis://:${_REDIS_PW_ENCODED}@${REDIS_HOST}:${REDIS_PORT}|" config/cable.yml 2>/dev/null || true

info "  ✓ 配置完成"

# ═══════════════════════════════════════════════
# 4. 数据库初始化
# ═══════════════════════════════════════════════
step "[4/8] 数据库初始化..."

_pg_sql() {
    if ${REMOTE}; then
        PGPASSWORD="${PG_PASSWORD}" psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" "$@"
    else
        su - postgres -c "psql \"\$@\" " _ "$@"
    fi
}

DB_EXISTS=$(_pg_sql -tAc "SELECT 1 FROM pg_database WHERE datname='gitlabhq_production'" 2>/dev/null || echo "0")
if [ "${DB_EXISTS}" = "1" ]; then
    SCHEMA_DONE=$(_pg_sql -d gitlabhq_production -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='schema_migrations'" 2>/dev/null || echo "0")
    if [ "${SCHEMA_DONE}" -gt 0 ]; then
        ROWS=$(_pg_sql -d gitlabhq_production -tAc "SELECT count(*) FROM schema_migrations" 2>/dev/null || echo "0")
        info "  ✓ 数据库已初始化 (${ROWS} migrations)，跳过 rake gitlab:setup"
    else
        info "  数据库存在但未初始化，执行 rake gitlab:setup..."
    fi
else
    _pg_sql -d template1 -c "CREATE USER git CREATEDB;" 2>/dev/null || true
    _pg_sql -d template1 -c "ALTER USER git WITH PASSWORD '${PG_PASSWORD}';" 2>/dev/null || true
    _pg_sql -d template1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" 2>/dev/null || true
    _pg_sql -d template1 -c "CREATE EXTENSION IF NOT EXISTS btree_gist;" 2>/dev/null || true
    _pg_sql -d template1 -c "CREATE EXTENSION IF NOT EXISTS plpgsql;" 2>/dev/null || true
    _pg_sql -d template1 -c "CREATE DATABASE gitlabhq_production OWNER git;" 2>/dev/null || true
    info "  ✓ 数据库已创建"
fi

# 如果 schema 未初始化，运行 setup
SCHEMA_DONE=$(_pg_sql -d gitlabhq_production -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='schema_migrations'" 2>/dev/null || echo "0")
if [ "${SCHEMA_DONE}" -eq 0 ]; then
    info "  执行 rake gitlab:setup（约 2-5 分钟）..."
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" \
        DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rake gitlab:setup RAILS_ENV=production force=yes --trace 2>&1 | tee /tmp/rake_setup.log \
        || { tail -80 /tmp/rake_setup.log; err "rake gitlab:setup 失败"; }
    info "  ✓ GitLab 初始化完成"
fi

# ═══════════════════════════════════════════════
# 5. Systemd 服务
# ═══════════════════════════════════════════════
step "[5/8] 配置 Systemd 服务..."

UNIT_DIR="/etc/systemd/system"
SYSTEMD_SRC="${GITLAB_DIR}/lib/support/systemd"

if [ -d "${SYSTEMD_SRC}" ]; then
    for unit in "${SYSTEMD_SRC}"/*.service "${SYSTEMD_SRC}"/gitlab.target; do
        [ -f "${unit}" ] 2>/dev/null || continue
        unit_name=$(basename "${unit}")
        cp "${unit}" "${UNIT_DIR}/${unit_name}"
    done
    info "  ✓ 已部署 GitLab systemd 单元"

    # ── 修正 Workhorse 配置 ──
    _WH_SVC="${UNIT_DIR}/gitlab-workhorse.service"
    if [ -f "${_WH_SVC}" ]; then
        # authBackend 端口 → 3000（与 Puma 一致）
        if grep -q 'authBackend.*8080' "${_WH_SVC}" 2>/dev/null; then
            sed -i 's|-authBackend http://127.0.0.1:8080|-authBackend http://127.0.0.1:3000|' "${_WH_SVC}"
        fi
        # 移除不存在的 authSocket
        if grep -q '\-authSocket' "${_WH_SVC}" 2>/dev/null; then
            _PUMA_SOCKET="${GITLAB_DIR}/tmp/sockets/gitlab.socket"
            if [ ! -S "${_PUMA_SOCKET}" ]; then
                sed -i 's|-authSocket [^ ]* ||' "${_WH_SVC}"
            fi
        fi
    fi
else
    warn "  使用最小化 systemd 模板..."
    # (使用 install_gitlab_source.sh 中的 fallback 模板逻辑)
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
After=network.target postgresql.service redis.service
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
    # Workhorse (Unix socket + Puma TCP 3000)
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
fi

systemctl daemon-reload
info "  ✓ systemd 服务就绪"

# ═══════════════════════════════════════════════
# 6. 启动 GitLab
# ═══════════════════════════════════════════════
step "[6/8] 启动 GitLab..."

for svc in gitlab-gitaly gitlab-workhorse gitlab-puma gitlab-sidekiq; do
    if [ -f "${UNIT_DIR}/${svc}.service" ]; then
        systemctl enable "${svc}" 2>/dev/null || true
        systemctl restart "${svc}" 2>&1 || warn "${svc} 启动有警告"
        sleep 2
        if systemctl is-active "${svc}" &>/dev/null; then
            info "  ✓ ${svc}"
        else
            warn "  ✗ ${svc} 启动失败，检查: journalctl -u ${svc} -n 20"
        fi
    fi
done

# ═══════════════════════════════════════════════
# 7. Nginx 反向代理
# ═══════════════════════════════════════════════
step "[7/8] Nginx 反向代理..."

NGINX_SCRIPT="${_SCRIPT_DIR}/../../nginx/install_nginx.sh"

# 安装 Nginx
if [ -x /usr/local/nginx/sbin/nginx ] || [ -x /usr/sbin/nginx ]; then
    info "  ✓ Nginx 已安装"
else
    if [ -f "${NGINX_SCRIPT}" ]; then
        bash "${NGINX_SCRIPT}" --port "${GITLAB_PORT}" || true
    else
        dnf install -y nginx 2>/dev/null || true
    fi
fi

# 定位 Nginx
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

    # 使用模板生成 gitlab.conf
    _TEMPLATE="${_SCRIPT_DIR}/../../nginx/conf.d/gitlab.conf"
    if [ -f "${_TEMPLATE}" ]; then
        cp "${_TEMPLATE}" "${NGINX_CONF_DIR}/gitlab.conf"
        sed -i "s|{{GITLAB_DIR}}|${GITLAB_DIR}|g"   "${NGINX_CONF_DIR}/gitlab.conf"
        sed -i "s|{{GITLAB_DOMAIN}}|${GITLAB_DOMAIN}|g" "${NGINX_CONF_DIR}/gitlab.conf"
        sed -i "s|{{GITLAB_PORT}}|${GITLAB_PORT}|g"   "${NGINX_CONF_DIR}/gitlab.conf"
    else
        # 最小化配置
        cat > "${NGINX_CONF_DIR}/gitlab.conf" << NGXMIN
upstream gitlab-workhorse {
    server unix:${GITLAB_DIR}/tmp/sockets/gitlab-workhorse.socket fail_timeout=0;
}
server {
    listen ${GITLAB_PORT};
    server_name _;
    root ${GITLAB_DIR}/public;
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
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://gitlab-workhorse;
    }
}
NGXMIN
    fi

    # include conf.d
    if ! grep -q "conf\.d/\*\.conf" "${NGINX_CONF_MAIN}" 2>/dev/null; then
        sed -i '/^http {/a\    include '"${NGINX_CONF_DIR}"'/*.conf;' "${NGINX_CONF_MAIN}" 2>/dev/null || true
    fi

    # 启动 Nginx
    if ${_NGINX_BIN} -t 2>&1; then
        if systemctl is-active nginx &>/dev/null; then
            systemctl reload nginx
        else
            systemctl enable nginx 2>/dev/null || true
            systemctl start nginx
        fi
        sleep 2

        # ── 修正权限 ──
        if ! id nginx 2>/dev/null | grep -q 'git'; then
            usermod -a -G git nginx 2>/dev/null || true
        fi
        chmod g+x /home/git 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true

        systemctl is-active nginx &>/dev/null && info "  ✓ Nginx 已启动（端口 ${GITLAB_PORT}）" \
            || warn "  ✗ Nginx 启动失败"
    else
        warn "  ✗ Nginx 配置语法检查未通过"
    fi
else
    warn "  ✗ 未找到 nginx，跳过"
    info "  直接访问: http://${GITLAB_DOMAIN}:3000"
fi

# ═══════════════════════════════════════════════
# 8. 验证 + 完成
# ═══════════════════════════════════════════════
step "[8/8] 验证..."

# 等待就绪
READY=false
for i in $(seq 1 30); do
    STATUS=$(curl -sk --connect-timeout 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GITLAB_PORT}/help" 2>/dev/null || echo "000")
    if [ "${STATUS}" = "200" ] || [ "${STATUS}" = "302" ]; then
        READY=true
        break
    fi
    [ $i -eq 30 ] && warn "超时 (${i}s)" || sleep 2
done

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

# 设置 root 密码
if ${READY}; then
    cd "${GITLAB_DIR}"
    sudo -u git -H env PATH="/usr/local/ruby/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin:$PATH" \
        bundle exec rails runner "user = User.find_by(username:'root'); user.password='${ROOT_PASS}'; user.password_confirmation='${ROOT_PASS}'; user.save!" RAILS_ENV=production 2>/dev/null \
        && info "  ✓ root 密码已设置" || true
fi

# 完成
echo ""
echo "============================================"
echo "  GitLab CE 预编译包部署完成"
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
echo "  卸载:    bash build/clean_gitlab.sh source --data"
echo "  重新部署: bash start_gitlab.sh ${GITLAB_DOMAIN}"
echo "============================================"
