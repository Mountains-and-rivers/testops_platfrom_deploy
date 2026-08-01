#!/bin/bash
# ============================================================
# Wiki.js Docker 入口
# ============================================================
set -e

# 默认配置（可通过环境变量覆盖）
WIKI_PORT="${WIKI_PORT:-3000}"
DB_TYPE="${DB_TYPE:-postgres}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-wiki}"
DB_USER="${DB_USER:-postgres}"
DB_PASS="${DB_PASS:-Pg1@zendao2024}"
DATA_DIR="${DATA_DIR:-/data/wiki}"
LOG_LEVEL="${LOG_LEVEL:-info}"

# 首次启动生成配置
if [ ! -f /opt/wiki/config.yml ]; then
    cat > /opt/wiki/config.yml << EOF
port: ${WIKI_PORT}
bindIP: 0.0.0.0
db:
  type: ${DB_TYPE}
  host: ${DB_HOST}
  port: ${DB_PORT}
  db: ${DB_NAME}
  user: ${DB_USER}
  pass: ${DB_PASS}
  ssl: false
logLevel: ${LOG_LEVEL}
dataPath: ${DATA_DIR}
EOF
fi

exec node /opt/wiki/server
