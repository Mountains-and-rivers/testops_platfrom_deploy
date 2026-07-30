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
FAILED=0

# 检查 git 用户
id git &>/dev/null && info "  ✓ git 用户" || { warn "  ✗ git 用户不存在，请先执行 build_gitlab_source.sh"; FAILED=1; }

# 检查源码目录
[ -f "${GITLAB_DIR}/Gemfile" ] && info "  ✓ 源码: ${GITLAB_DIR}" \
    || { warn "  ✗ 源码不存在: ${GITLAB_DIR}，请先执行 build_gitlab_source.sh"; FAILED=1; }

# 检查 Gitaly
[ -f "${GITALY_DIR}/gitaly" ] && info "  ✓ Gitaly: ${GITALY_DIR}" \
    || { warn "  ✗ Gitaly 未编译: ${GITALY_DIR}"; FAILED=1; }

# 检查 GitLab Shell
[ -f "${SHELL_DIR}/bin/gitlab-shell" ] || [ -d "${SHELL_DIR}/.git" ] \
    && info "  ✓ gitlab-shell: ${SHELL_DIR}" \
    || { warn "  ✗ gitlab-shell 缺失: ${SHELL_DIR}"; FAILED=1; }

# 检查 GitLab Workhorse
[ -f "${WORKHORSE_DIR}/gitlab-workhorse" ] && info "  ✓ workhorse: ${WORKHORSE_DIR}" \
    || { warn "  ✗ workhorse 未编译: ${WORKHORSE_DIR}"; FAILED=1; }

# 检查 PostgreSQL 运行
if systemctl is-active postgresql &>/dev/null; then
    info "  ✓ PostgreSQL 运行中"
elif pg_isready &>/dev/null 2>&1; then
    info "  ✓ PostgreSQL 运行中"
else
    warn "  ✗ PostgreSQL 未运行，请先: systemctl start postgresql"; FAILED=1
fi

# 检查 Redis 运行
systemctl is-active redis &>/dev/null && info "  ✓ Redis 运行中" \
    || { warn "  ✗ Redis 未运行，请先: systemctl start redis"; FAILED=1; }

# 检查 Ruby 可用
sudo -u git -H bash -c 'ruby --version' &>/dev/null && info "  ✓ Ruby 可用" \
    || { warn "  ✗ Ruby 不可用"; FAILED=1; }

# 检查 Node/Yarn 可用
command -v yarn &>/dev/null && info "  ✓ Yarn 可用" \
    || { warn "  ✗ Yarn 不可用，请先执行 build_gitlab_source.sh"; FAILED=1; }

[ $FAILED -eq 1 ] && err "依赖检查未通过，请修复后重试"

# ═══════════════════════════════════════════════
# 1. 数据库初始化
# ═══════════════════════════════════════════════
step "[1/7] 数据库初始化..."

# 检查数据库是否已存在
DB_EXISTS=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='gitlabhq_production'\"" 2>/dev/null || echo "0")
if [ "${DB_EXISTS}" = "1" ]; then
    info "  ✓ 数据库 gitlabhq_production 已存在，跳过初始化"
else
    info "  创建 git 用户和数据库..."
    su - postgres -c "psql -d template1 -c \"CREATE USER git CREATEDB;\"" 2>/dev/null || true
    su - postgres -c "psql -d template1 -c \"ALTER USER git WITH PASSWORD 'Pg1@zendao2024';\"" 2>/dev/null || true

    # 扩展（官方要求 pg_trgm + btree_gist + plpgsql）
    su - postgres -c "psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\"" 2>/dev/null || true
    su - postgres -c "psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS btree_gist;\"" 2>/dev/null || true
    su - postgres -c "psql -d template1 -c \"CREATE EXTENSION IF NOT EXISTS plpgsql;\"" 2>/dev/null || true

    # 创建数据库
    su - postgres -c "psql -d template1 -c \"CREATE DATABASE gitlabhq_production OWNER git;\"" 2>/dev/null || true

    # 验证
    DB_EXISTS=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='gitlabhq_production'\"" 2>/dev/null || echo "0")
    [ "${DB_EXISTS}" = "1" ] && info "  ✓ 数据库创建成功" || err "数据库创建失败"
fi

# ═══════════════════════════════════════════════
# 2. 初始化 GitLab（rake gitlab:setup）
# ═══════════════════════════════════════════════
step "[2/7] 初始化 GitLab（DB schema + seed）..."

cd "${GITLAB_DIR}"

# 检查是否已初始化（有 schema_migrations 表说明已完成）
SCHEMA_DONE=$(su - postgres -c "psql -tAc \"SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='schema_migrations'\"" gitlabhq_production 2>/dev/null || echo "0")
if [ "${SCHEMA_DONE}" = "1" ]; then
    ROWS=$(su - postgres -c "psql -tAc \"SELECT count(*) FROM schema_migrations\"" gitlabhq_production 2>/dev/null || echo "0")
    info "  ✓ schema_migrations 已存在 (${ROWS} migrations)，跳过 rake gitlab:setup"
else
    # 先确保 Gitaly 在运行（rake gitlab:setup 需要）
    if ! systemctl is-active gitlab-gitaly &>/dev/null 2>&1; then
        info "  先启动 Gitaly（rake gitlab:setup 需要）..."
        if [ -f "${GITLAB_DIR}/lib/support/systemd/gitlab-gitaly.service" ]; then
            cp "${GITLAB_DIR}/lib/support/systemd/gitlab-gitaly.service" /etc/systemd/system/
            systemctl daemon-reload
            systemctl enable gitlab-gitaly
            systemctl start gitlab-gitaly
            sleep 3
            systemctl is-active gitlab-gitaly &>/dev/null || warn "Gitaly 可能未正常启动"
        else
            warn "  systemd 服务文件不存在，跳过 Gitaly 预启动"
        fi
    fi

    info "  执行 rake gitlab:setup（创建表结构 + 种子数据）..."
    info "  （此步骤需要 2-5 分钟，请耐心等待）"
    sudo -u git -H bundle exec rake gitlab:setup RAILS_ENV=production force=yes 2>&1 | tail -10 \
        || err "rake gitlab:setup 失败（检查数据库连接和 Redis）"

    info "  ✓ GitLab 初始化完成"
fi

# ═══════════════════════════════════════════════
# 3. 编译前端资源
# ═══════════════════════════════════════════════
step "[3/7] 编译前端资源..."

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
    info "  yarn install --production --pure-lockfile..."
    sudo -u git -H yarn install --production --pure-lockfile 2>&1 | tail -5 \
        || { warn "yarn install 失败，尝试不带 --pure-lockfile..."; sudo -u git -H yarn install --production 2>&1 | tail -5; }
    info "  ✓ Node 依赖安装完成"
fi

# 前端资源编译
if [ -d "public/assets" ] && [ "$(ls public/assets/ | wc -l)" -gt 10 ]; then
    info "  ✓ public/assets 已编译，跳过 assets:compile"
else
    info "  编译前端资源（此步骤 5-15 分钟）..."
    sudo -u git -H bundle exec rake gitlab:assets:compile RAILS_ENV=production NODE_ENV=production 2>&1 | tail -5 \
        || err "前端资源编译失败（可能需要更多内存，建议 >= 8GB）"
    info "  ✓ 前端资源编译完成"
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
    for unit in "${SYSTEMD_SRC}"/*.service "${SYSTEMD_SRC}"/gitlab.target 2>/dev/null; do
        [ -f "${unit}" ] || continue
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
ExecStart=${GITALY_DIR}/gitaly ${GITALY_DIR}/config.toml
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

    # Workhorse
    cat > "${UNIT_DIR}/gitlab-workhorse.service" << WORKHORSEUNIT
[Unit]
Description=GitLab Workhorse
After=network.target

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=${WORKHORSE_DIR}
Environment="HOME=${GITLAB_HOME}"
ExecStart=${WORKHORSE_DIR}/gitlab-workhorse -listenAddr 127.0.0.1:8181 -secretPath ${GITLAB_DIR}/.gitlab_workhorse_secret
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
# 6. 等待就绪
# ═══════════════════════════════════════════════
step "[6/7] 等待 GitLab 就绪..."

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
step "[7/7] 验证..."

# 服务状态
echo ""
echo "--- 服务状态 ---"
for svc in gitlab-gitaly gitlab-workhorse gitlab-puma gitlab-sidekiq; do
    if systemctl is-active "${svc}" &>/dev/null 2>&1; then
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
    sudo -u git -H bundle exec rails runner "user = User.find_by(username:'root'); user.password='${ROOT_PASS}'; user.password_confirmation='${ROOT_PASS}'; user.save!" RAILS_ENV=production 2>/dev/null \
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
echo "  检查: cd ${GITLAB_DIR} && sudo -u git -H bundle exec rake gitlab:check RAILS_ENV=production"
echo "  卸载: bash clean_gitlab.sh source --data"
echo "============================================"
