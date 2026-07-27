#!/bin/bash
# ============================================================
# 禅道 Docker 入口脚本
# 首次启动生成 my.php → 等待 MySQL → 启动 Apache
# ============================================================
set -e

ZENTAO_ROOT="/var/www/zentaopms"
ZENTAO_CONFIG="${ZENTAO_ROOT}/config/my.php"

echo ">>> ZenTao v${ZENTAO_VERSION} 容器启动"

# ---- 1. 首次启动：生成配置文件 ----
if [ ! -f "${ZENTAO_CONFIG}" ]; then
    echo ">>> 首次启动，生成 my.php..."

    # 等待外部 MySQL（最多 120 秒）
    for i in $(seq 1 24); do
        if php -r "
            try {
                new PDO('mysql:host=${ZT_MYSQL_HOST};port=${ZT_MYSQL_PORT};charset=utf8mb4',
                    '${ZT_MYSQL_USER}', '${ZT_MYSQL_PASSWORD}');
                echo 'OK';
            } catch(Exception \$e) { exit(1); }
        " 2>/dev/null; then
            echo ">>> MySQL 已就绪 (${ZT_MYSQL_HOST}:${ZT_MYSQL_PORT}, 尝试 ${i}/24)"
            break
        fi
        sleep 5
    done

    # 写入 my.php
    cat > "${ZENTAO_CONFIG}" << MYEOF
<?php
\$config->installed       = true;
\$config->debug           = false;
\$config->requestType     = 'PATH_INFO';
\$config->timezone        = 'Asia/Shanghai';
\$config->db->host        = '${ZT_MYSQL_HOST}';
\$config->db->port        = '${ZT_MYSQL_PORT}';
\$config->db->name        = '${ZT_MYSQL_DB}';
\$config->db->user        = '${ZT_MYSQL_USER}';
\$config->db->password    = '${ZT_MYSQL_PASSWORD}';
\$config->db->prefix      = 'zt_';
\$config->db->driver      = 'pdo';
\$config->default->lang   = 'zh-cn';
MYEOF
    chmod 640 "${ZENTAO_CONFIG}"
    echo ">>> my.php 已生成"
fi

# ---- 2. 启动 Apache ----
echo ">>> 启动 Apache httpd..."
exec "$@"
