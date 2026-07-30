#!/bin/bash
# ============================================================
# 禅道 Docker 入口脚本
# 首次启动: 等待 MySQL → 导入 schema → 写配置 → 启动 Apache
# ============================================================
set -eo pipefail

ZENTAO_ROOT="/var/www/zentaopms"
ZENTAO_CONFIG="${ZENTAO_ROOT}/config/my.php"

echo ">>> ZenTao v${ZENTAO_VERSION} 容器启动"

# ---- 1. 首次启动：初始化数据库 + 生成配置文件 ----
if [ ! -f "${ZENTAO_CONFIG}" ]; then
    echo ">>> 首次启动，等待 MySQL..."

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

    # 确保数据库存在
    mysql -h "${ZT_MYSQL_HOST}" -P "${ZT_MYSQL_PORT}" -u "${ZT_MYSQL_USER}" -p"${ZT_MYSQL_PASSWORD}" \
        -e "CREATE DATABASE IF NOT EXISTS \`${ZT_MYSQL_DB}\` DEFAULT CHARSET utf8mb4" || true

    # 导入完整 schema（替换占位符后执行；幂等，失败不影响启动）
    if [ -f "${ZENTAO_ROOT}/db/zentao.sql" ]; then
        echo ">>> 导入数据库 schema..."
        sed "s/__DATABASE__/${ZT_MYSQL_DB}/g; s/__PREFIX__/zt_/g" "${ZENTAO_ROOT}/db/zentao.sql" | \
            mysql -h "${ZT_MYSQL_HOST}" -P "${ZT_MYSQL_PORT}" -u "${ZT_MYSQL_USER}" -p"${ZT_MYSQL_PASSWORD}" "${ZT_MYSQL_DB}" 2>&1 | grep -v 'Duplicate key' || true
        echo ">>> schema 导入完成"
    fi

    # 写入默认数据（公司 / 版本号 / admin 用户 / 分组）
    echo ">>> 写入默认数据..."
    mysql -h "${ZT_MYSQL_HOST}" -P "${ZT_MYSQL_PORT}" -u "${ZT_MYSQL_USER}" -p"${ZT_MYSQL_PASSWORD}" "${ZT_MYSQL_DB}" <<'ENDINIT' || true
INSERT IGNORE INTO zt_company (name, phone, admins) VALUES ('默认公司', '', ',admin,');
INSERT IGNORE INTO zt_config (vision, owner, module, section, `key`, value) VALUES ('rnd', 'system', 'common', 'global', 'version', '22.3');
INSERT IGNORE INTO zt_group (name, role, `desc`, acl, developer, vision) VALUES ('guest', 'guest', 'Guest', '', 0, 'rnd');
INSERT IGNORE INTO zt_group (name, role, `desc`, acl, developer, vision) VALUES ('admin', 'admin', 'Admin', '', 1, 'rnd');
INSERT IGNORE INTO zt_user (account, `password`, role, dept, company, realname, nickname, commiter, gender, email, `type`) VALUES ('admin', 'e10adc3949ba59abbe56e057f20f883e', 'top', 0, 1, 'Admin', 'Admin', 'admin', 'm', 'admin@test.com', 'inside');
ENDINIT

    # 创建运行时必需目录
    mkdir -p "${ZENTAO_ROOT}/www/data" && chmod 777 "${ZENTAO_ROOT}/www/data"

    # 写入 my.php
    cat > "${ZENTAO_CONFIG}" << MYEOF
<?php
\$config->installed       = true;
\$config->debug           = false;
\$config->requestType     = 'PATH_INFO';
\$config->webRoot         = '/';
\$config->timezone        = 'Asia/Shanghai';
\$config->db->host        = '${ZT_MYSQL_HOST}';
\$config->db->port        = '${ZT_MYSQL_PORT}';
\$config->db->name        = '${ZT_MYSQL_DB}';
\$config->db->user        = '${ZT_MYSQL_USER}';
\$config->db->password    = '${ZT_MYSQL_PASSWORD}';
\$config->db->prefix      = 'zt_';
\$config->db->driver      = 'mysql';
\$config->default->lang   = 'zh-cn';
MYEOF
    chmod 640 "${ZENTAO_CONFIG}"
    echo ">>> my.php 已生成"
fi

# ---- 2. 启动 Apache ----
echo ">>> 启动 Apache httpd..."
exec "$@"
