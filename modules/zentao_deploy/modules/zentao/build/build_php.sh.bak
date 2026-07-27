#!/bin/bash
# ============================================================
# 宿主机编译 PHP 8.1 + Apache 2.4（CentOS Stream 9）
# 自动检测依赖 → 编译 → 拉源码 → 配置 → 启动 → 健康检查
# 用法: bash build_php.sh
# ============================================================
set -euo pipefail

# 脚本所在目录的绝对路径（在 cd 前保存，确保本地包查找始终正确）
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$(pwd)")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()  { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

PHP_VERSION="${PHP_VERSION:-8.1.27}"
HTTPD_VERSION="${HTTPD_VERSION:-2.4.62}"
PHP_DIR="/opt/php"
HTTPD_DIR="/opt/httpd"
ZENTAO_DIR="/var/www/zentaopms"
ZENTAO_SRC="/opt/build/zentaopms/source"
SCRIPT_DIR="${_SCRIPT_DIR}"
CACHE_DIR="${CACHE_DIR:-/tmp/build-cache}"
mkdir -p "${CACHE_DIR}"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="${PHP_DIR}/bin:${HTTPD_DIR}/bin:${PATH}"

# 下载函数：本地缓存优先，验证完整性
download() {
    local url="$1" fname="$2"
    # 按优先级查找：脚本目录 → 缓存目录 → 当前目录
    for d in "${SCRIPT_DIR}/" "${CACHE_DIR}/" "./"; do
        [ -f "${d}${fname}" ] && [ -s "${d}${fname}" ] && tar -tzf "${d}${fname}" >/dev/null 2>&1 && { [ "${d}${fname}" != "./${fname}" ] && cp "${d}${fname}" "./${fname}"; info "  使用本地: ${d}${fname}"; return 0; }
        [ -f "${d}${fname}" ] && warn "  损坏，删除: ${d}${fname}" && rm -f "${d}${fname}"
    done
    cd /tmp  # 确保 CWD 有效再下载
    info "  下载: ${url}"; wget --show-progress -O "${fname}" "${url}" || err "下载失败: ${url}"
    tar -tzf "${fname}" >/dev/null 2>&1 || { rm -f "${fname}"; err "文件损坏: ${fname}"; }
    cp "${fname}" "${CACHE_DIR}/${fname}" 2>/dev/null || true
}

echo "============================================"
echo "  PHP ${PHP_VERSION} + Apache ${HTTPD_VERSION} 编译部署"
echo "============================================"

# 编译状态检测
PHP_COMPILED=false; APACHE_COMPILED=false
[ -f "${PHP_DIR}/bin/php" ] && { info "PHP 已编译: $(${PHP_DIR}/bin/php -v 2>&1 | head -1)"; PHP_COMPILED=true; }
[ -f "${HTTPD_DIR}/bin/httpd" ] && { info "Apache 已编译: $(${HTTPD_DIR}/bin/httpd -v 2>&1 | head -1)"; APACHE_COMPILED=true; }
${PHP_COMPILED} && ${APACHE_COMPILED} && info "编译产物已存在，跳过编译步骤"

# ---- 0. C编译器修复 ----
step "[0] 检查 C 编译器..."
echo "int main(){return 0;}" | gcc -x c - -o /tmp/gcc_test 2>/dev/null && rm -f /tmp/gcc_test \
    || { warn "gcc 故障，修复中..."; dnf distro-sync --allowerasing -y glibc glibc-devel glibc-headers glibc-common libgcc libstdc++ 2>/dev/null || true; dnf reinstall -y gcc glibc-devel 2>/dev/null || true; }

# ---- 1. 系统编译依赖 ----
step "[1/12] 系统编译依赖..."
dnf install -y epel-release
dnf install -y --allowerasing gcc gcc-c++ make autoconf libtool bison re2c pkgconfig cmake \
    libxml2-devel libpng-devel libjpeg-turbo-devel freetype-devel openssl-devel curl-devel libicu-devel sqlite-devel httpd-devel wget unzip

# ---- 2. libzip（源码编译）----
step "[2/12] libzip..."
pkg-config --exists libzip 2>/dev/null && info "  libzip $(pkg-config --modversion libzip) 已安装" || {
    warn "  从源码编译..."; cd /tmp; rm -rf libzip-1.10.1*
    download https://libzip.org/download/libzip-1.10.1.tar.gz libzip-1.10.1.tar.gz
    tar -xzf libzip-1.10.1.tar.gz && cd libzip-1.10.1 && mkdir build && cd build && cmake .. && make -j$(nproc) && make install
    rm -rf /tmp/libzip-1.10.1*; ldconfig; info "  libzip OK"
}

# ---- 3. oniguruma（源码编译）----
step "[3/12] oniguruma..."
pkg-config --exists oniguruma 2>/dev/null && info "  oniguruma $(pkg-config --modversion oniguruma) 已安装" || {
    warn "  从源码编译..."; cd /tmp; rm -rf onig-6.9.9*
    download https://github.com/kkos/oniguruma/releases/download/v6.9.9/onig-6.9.9.tar.gz onig-6.9.9.tar.gz
    tar -xzf onig-6.9.9.tar.gz && cd onig-6.9.9 && ./configure && make -j$(nproc) && make install
    rm -rf /tmp/onig-6.9.9*; ldconfig; info "  oniguruma OK"
}
echo "/usr/local/lib" > /etc/ld.so.conf.d/php-local.conf 2>/dev/null || true
echo "/usr/local/lib64" >> /etc/ld.so.conf.d/php-local.conf 2>/dev/null || true
ldconfig
export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib64:${LD_LIBRARY_PATH:-}"

# ---- 4. jpeg ----
step "[4/12] jpeg 兼容..."
[ ! -f "/usr/lib64/libjpeg.so" ] && [ -f "/usr/lib64/libjpeg.so.62" ] && ln -sf /usr/lib64/libjpeg.so.62 /usr/lib64/libjpeg.so 2>/dev/null || true
info "  jpeg OK"

# ---- 5. Apache ----
step "[5/12] 编译 Apache ${HTTPD_VERSION}..."
if ! ${APACHE_COMPILED}; then
    cd /tmp; download https://archive.apache.org/dist/httpd/httpd-${HTTPD_VERSION}.tar.gz httpd-${HTTPD_VERSION}.tar.gz
    tar -xzf httpd-${HTTPD_VERSION}.tar.gz && cd httpd-${HTTPD_VERSION}
    ./configure --prefix=${HTTPD_DIR} --enable-ssl --enable-rewrite --enable-headers --enable-deflate --enable-proxy --enable-proxy-fcgi --with-mpm=prefork
    make -j$(nproc) && make install; rm -rf /tmp/httpd-${HTTPD_VERSION}*; info "  Apache OK"
else info "  跳过"; fi

# ---- 6. PHP ----
step "[6/12] 编译 PHP ${PHP_VERSION}..."
if ! ${PHP_COMPILED}; then
    cd /tmp; download https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz php-${PHP_VERSION}.tar.gz
    tar -xzf php-${PHP_VERSION}.tar.gz && cd php-${PHP_VERSION}
    ./configure --prefix=${PHP_DIR} --with-apxs2=${HTTPD_DIR}/bin/apxs --with-config-file-path=${PHP_DIR}/etc --with-config-file-scan-dir=${PHP_DIR}/etc/conf.d --enable-mbstring --enable-xml --enable-dom --enable-fileinfo --enable-intl --enable-bcmath --enable-opcache --enable-exif --with-zip --with-curl --with-openssl --with-pdo-mysql=mysqlnd --with-mysqli=mysqlnd --with-freetype --with-jpeg --with-gd
    make -j$(nproc) && make install; rm -rf /tmp/php-${PHP_VERSION}*; info "  PHP OK"
else info "  跳过"; fi

# ---- 7. PHP 配置 ----
step "[7/12] PHP 配置..."
mkdir -p ${PHP_DIR}/etc/conf.d
cat > ${PHP_DIR}/etc/conf.d/zentao.ini << 'EOF'
[PHP]
memory_limit = 512M
post_max_size = 100M
upload_max_filesize = 100M
max_execution_time = 300
max_input_time = 300
date.timezone = Asia/Shanghai
opcache.enable = 1
opcache.memory_consumption = 256
EOF
cp ${HTTPD_DIR}/modules/libphp.so ${HTTPD_DIR}/modules/ 2>/dev/null || true
strip ${PHP_DIR}/bin/php ${HTTPD_DIR}/bin/httpd 2>/dev/null || true
info "  PHP 配置 OK"

# ---- 8. 源码 ----
step "[8/12] 获取禅道源码..."
if [ ! -f "${ZENTAO_SRC}/www/index.php" ]; then
    rm -rf "${ZENTAO_SRC}"
    mkdir -p "$(dirname "${ZENTAO_SRC}")"
    if [ -f "${SCRIPT_DIR}/zentaopms.zip" ]; then
        info "  解压本地: ${SCRIPT_DIR}/zentaopms.zip"
        unzip -qo "${SCRIPT_DIR}/zentaopms.zip" -d /tmp/zentaopms_extract
        # 自动适配 ZIP 内部结构：zentaopms-版本号/、zentaopms/ 或直接散文件
        EXTRACTED=$(ls /tmp/zentaopms_extract/ | head -1)
        if [ -d "/tmp/zentaopms_extract/${EXTRACTED}" ] && [ "$(ls -A /tmp/zentaopms_extract/ | wc -l)" -eq 1 ]; then
            mv "/tmp/zentaopms_extract/${EXTRACTED}" "${ZENTAO_SRC}"
        else
            mv /tmp/zentaopms_extract/* "${ZENTAO_SRC}" 2>/dev/null || mv /tmp/zentaopms_extract "${ZENTAO_SRC}" 2>/dev/null
        fi
        [ -f "${ZENTAO_SRC}/www/index.php" ] || err "ZIP 解压异常"
        rm -rf /tmp/zentaopms_extract
    elif [ -f "${CACHE_DIR}/zentaopms.zip" ]; then
        info "  解压缓存: ${CACHE_DIR}/zentaopms.zip"
        unzip -qo "${CACHE_DIR}/zentaopms.zip" -d /tmp/zentaopms_extract
        EXTRACTED=$(ls /tmp/zentaopms_extract/ | head -1)
        if [ -d "/tmp/zentaopms_extract/${EXTRACTED}" ] && [ "$(ls -A /tmp/zentaopms_extract/ | wc -l)" -eq 1 ]; then
            mv "/tmp/zentaopms_extract/${EXTRACTED}" "${ZENTAO_SRC}"
        else
            mv /tmp/zentaopms_extract/* "${ZENTAO_SRC}" 2>/dev/null || mv /tmp/zentaopms_extract "${ZENTAO_SRC}" 2>/dev/null
        fi
        [ -f "${ZENTAO_SRC}/www/index.php" ] || err "ZIP 解压异常"
        rm -rf /tmp/zentaopms_extract
    else
        info "  Git clone..."
        cd /tmp  # 确保 CWD 有效
        expect -c "log_user 1; set timeout 300; spawn git clone --depth 1 --branch main https://github.com/easysoft/zentaopms.git ${ZENTAO_SRC}; expect { \"*yes/no*\" { send \"yes\r\"; exp_continue } \"*fingerprint*\" { send \"yes\r\"; exp_continue } \"*Username*\" { send \"Mountains-and-rivers\r\"; exp_continue } \"*Password*\" { send \"Wgl,.2018\r\"; exp_continue } timeout { exit 1 } }" 2>&1
    fi
    [ -f "${ZENTAO_SRC}/www/index.php" ] || err "源码获取失败"
fi
rm -rf "${ZENTAO_DIR}"; cp -r "${ZENTAO_SRC}" "${ZENTAO_DIR}"
chown -R root:root "${ZENTAO_DIR}"; chmod -R 755 "${ZENTAO_DIR}"
info "  禅道已部署: ${ZENTAO_DIR}"

# ---- 9. 数据库配置 ----
step "[9/12] 数据库配置..."
cat > "${ZENTAO_DIR}/config/my.php" << 'MYEOF'
<?php
$config->installed       = true;
$config->debug           = false;
$config->requestType     = 'PATH_INFO';
$config->webRoot         = '/';
$config->timezone        = 'Asia/Shanghai';
$config->db->host        = '192.168.0.102';
$config->db->port        = '3306';
$config->db->name        = 'zendao';
$config->db->user        = 'root';
# ⚠️ 密码含 $：my.php 用单引号字符串，PHP 不会解析 $pr 为变量。← 与 MySQL 密码一致
$config->db->password    = 'Kd9$prL7sQ2!vzB4';
$config->db->prefix      = 'zt_';
$config->db->driver      = 'mysql';
$config->default->lang   = 'zh-cn';
MYEOF
chmod 644 "${ZENTAO_DIR}/config/my.php"
# 创建禅道运行时必需的 www/data 目录
mkdir -p "${ZENTAO_DIR}/www/data" && chmod 777 "${ZENTAO_DIR}/www/data"
# 确保数据库存在，导入完整 schema（zentao.sql 为当前版本的完整建表语句）
mysql -h 192.168.0.102 -P 3306 -u root -p'Kd9$prL7sQ2!vzB4' -e 'CREATE DATABASE IF NOT EXISTS zendao DEFAULT CHARSET utf8mb4' 2>/dev/null || true
if [ -f "${ZENTAO_DIR}/db/zentao.sql" ]; then
    # 替换 zentao.sql 中的占位符后导入（__DATABASE__ → 实际库名, __PREFIX__ → zt_）
    sed "s/__DATABASE__/zendao/g; s/__PREFIX__/zt_/g" "${ZENTAO_DIR}/db/zentao.sql" | \
        mysql -h 192.168.0.102 -P 3306 -u root -p'Kd9$prL7sQ2!vzB4' zendao 2>/dev/null && \
        info "  数据库表初始化完成 ($(mysql -h 192.168.0.102 -P 3306 -u root -p'Kd9$prL7sQ2!vzB4' zendao -NBe 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"zendao\"' 2>/dev/null) 张表)" || \
        warn "  数据库表初始化失败，请检查 MySQL 连接"
else
    warn "  zentao.sql 缺失，跳过数据库初始化"
fi
# 写入版本号 + 默认公司 + 管理员账号（admin / 123456）
mysql -h 192.168.0.102 -P 3306 -u root -p'Kd9$prL7sQ2!vzB4' zendao <<'ENDINIT' 2>/dev/null || true
INSERT IGNORE INTO zt_company (name, phone, admins) VALUES ('默认公司', '', ',admin,');
INSERT IGNORE INTO zt_config (vision, owner, module, section, `key`, value) VALUES ('rnd', 'system', 'common', 'global', 'version', '22.3');
INSERT IGNORE INTO zt_group (name, role, `desc`, acl, developer, vision) VALUES ('guest', 'guest', 'Guest', '', 0, 'rnd');
INSERT IGNORE INTO zt_group (name, role, `desc`, acl, developer, vision) VALUES ('admin', 'admin', 'Admin', '', 1, 'rnd');
INSERT IGNORE INTO zt_user (account, `password`, role, dept, company, realname, nickname, commiter, gender, email, `type`) VALUES ('admin', 'e10adc3949ba59abbe56e057f20f883e', 'top', 0, 1, 'Admin', 'Admin', 'admin', 'm', 'admin@test.com', 'inside');
ENDINIT
info "  数据库: 192.168.0.102:3306/zendao (done)"

# ---- 10. Apache 配置 ----
step "[10/12] Apache 配置..."
cat > ${HTTPD_DIR}/conf/httpd.conf << 'HTTPDCONF'
ServerRoot /opt/httpd
Listen 8080
User www
Group www
LoadModule mime_module modules/mod_mime.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule dir_module modules/mod_dir.so
LoadModule php_module modules/libphp.so
TypesConfig conf/mime.types
AddType text/javascript .js .mjs
DocumentRoot /var/www/zentaopms/www
<Directory />
    AllowOverride none
    Require all denied
</Directory>
<Directory /var/www/zentaopms/www>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
<FilesMatch \.php$>
  SetHandler application/x-httpd-php
</FilesMatch>
DirectoryIndex index.php index.html
ServerName localhost
HTTPDCONF
info "  Apache 配置 OK"

# ---- 11. 权限 ----
step "[11/12] 目录权限..."
# 确保 www 用户存在
id www 2>/dev/null || { groupadd -f www && useradd -r -g www -d /var/www -s /sbin/nologin www; }
mkdir -p "${ZENTAO_DIR}/www/data" "${ZENTAO_DIR}/tmp" "${ZENTAO_DIR}/log"
chmod -R 755 "${ZENTAO_DIR}"; chmod 644 "${ZENTAO_DIR}/config/my.php"
chmod -R 777 "${ZENTAO_DIR}/www/data" "${ZENTAO_DIR}/tmp" "${ZENTAO_DIR}/log"
info "  权限 OK"

# ---- 12. 准入检查 + 启动 + 验证 ----
step "[12/12] 启动..."

# 准入条件（任一不满足则退出）
FAILED=0
[ -f "${PHP_DIR}/bin/php" ]   && info "  ✓ PHP"    || { warn "  ✗ PHP 未编译"; FAILED=1; }
[ -f "${HTTPD_DIR}/bin/httpd" ] && info "  ✓ Apache" || { warn "  ✗ Apache 未编译"; FAILED=1; }
[ -f "${ZENTAO_DIR}/config/my.php" ] && info "  ✓ my.php" || { warn "  ✗ my.php 缺失，请先执行 build_php.sh"; FAILED=1; }
[ -f "${ZENTAO_DIR}/www/index.php" ] && info "  ✓ 源码"    || { warn "  ✗ 源码缺失"; FAILED=1; }
# Apache 配置语法
"${HTTPD_DIR}/bin/httpd" -t 2>/dev/null && info "  ✓ Apache 配置" || { warn "  ✗ Apache 配置错误"; "${HTTPD_DIR}/bin/httpd" -t 2>&1 | tail -3; FAILED=1; }
# MySQL（不可达仅告警）
php -r "try{new PDO('mysql:host=192.168.0.102;port=3306;charset=utf8mb4','root','Kd9\$prL7sQ2!vzB4');}catch(Exception \$e){exit(1);}" 2>/dev/null && info "  ✓ MySQL" || warn "  ✗ MySQL 不可达"

[ $FAILED -eq 1 ] && { warn "准入检查未通过"; exit 1; }

# 优雅停旧进程 → 启动
"${HTTPD_DIR}/bin/apachectl" -k graceful-stop 2>/dev/null || pkill httpd 2>/dev/null || true
sleep 1
"${HTTPD_DIR}/bin/httpd" -D FOREGROUND &
sleep 3

# 进程验证
pgrep -f "httpd" > /dev/null && info "  进程 OK" || { warn "  进程启动失败"; tail -10 "${HTTPD_DIR}/logs/error_log" 2>/dev/null; exit 1; }

# HTTP 验证
for i in $(seq 1 10); do
    C=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null)
    [ "$C" = "200" ] || [ "$C" = "302" ] && { info "  HTTP ${C} (${i}/10)"; break; }
    [ $i -eq 10 ] && { warn "  HTTP 未响应 (last: ${C})"; exit 1; }
    sleep 2
done

echo ""
echo "============================================"
echo "  PHP:    $(${PHP_DIR}/bin/php -v 2>&1 | head -1)"
echo "  Apache: $(${HTTPD_DIR}/bin/httpd -v 2>&1 | head -1)"
echo "  禅道:   ${ZENTAO_DIR}"
echo "  数据库: 192.168.0.102:3306/zendao"
echo "  访问:   http://192.168.0.102:8080"
echo "  日志:   ${HTTPD_DIR}/logs/error_log"
echo "============================================"
