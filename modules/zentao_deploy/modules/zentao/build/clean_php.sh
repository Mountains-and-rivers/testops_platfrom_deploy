#!/bin/bash
# ============================================================
# 精准清理脚本 — 与 build_php.sh 完全对称
# 用法: bash clean_php.sh [OPTIONS]
#   -a  清理全部（默认）
#   -z  仅清理禅道部署
#   -p  仅清理 PHP + Apache 编译产物
#   -d  仅清理依赖库(libzip/oniguruma)
#   -c  仅清理缓存
#   -u  仅清理 www 用户
#   -h  帮助
# ============================================================
set -euo pipefail

PHP_DIR="/opt/php"
HTTPD_DIR="/opt/httpd"
ZENTAO_DIR="/var/www/zentaopms"
ZENTAO_SRC="/opt/build/zentaopms/source"
CLEAN_ALL=false; CLEAN_ZENTAO=false; CLEAN_PHP=false; CLEAN_DEPS=false; CLEAN_CACHE=false; CLEAN_USER=false

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "${CYAN}[STEP]${NC}  $*"; }

usage() {
    cat << 'USAGE'
============================================
  精准清理脚本（与 build_php.sh 对称）
============================================
用法: bash clean_php.sh [OPTIONS]

选项:
  -a    清理全部（禅道+PHP+Apache+依赖库+缓存+www用户）
  -z    仅清理禅道部署（/var/www/zentaopms + source缓存 + 停Apache）
  -p    仅清理 PHP + Apache 编译产物（/opt/php /opt/httpd）
  -d    仅清理依赖库（libzip/oniguruma/jpeg链接/ldconfig）
  -c    仅清理缓存（/tmp/build-cache + 临时编译目录）
  -u    仅清理 www 用户和组
  -h    帮助

示例:
  bash clean_php.sh             # 清理全部 (同 -a)
  bash clean_php.sh -z          # 只清理禅道，保留 PHP/Apache
  bash clean_php.sh -p -d -c    # 清理编译产物+依赖库+缓存
============================================
USAGE
    exit 0
}

while getopts "azpdcuh" opt; do
    case $opt in
        a) CLEAN_ALL=true ;; z) CLEAN_ZENTAO=true ;; p) CLEAN_PHP=true ;;
        d) CLEAN_DEPS=true ;; c) CLEAN_CACHE=true ;; u) CLEAN_USER=true ;;
        h) usage ;; *) usage ;;
    esac
done
# 无参数默认全部
$CLEAN_ALL || $CLEAN_ZENTAO || $CLEAN_PHP || $CLEAN_DEPS || $CLEAN_CACHE || $CLEAN_USER || CLEAN_ALL=true

clean_zentao() {
    step "清理禅道..."
    # 停服务
    pkill -9 httpd 2>/dev/null || true
    # 删部署源码
    rm -rf "${ZENTAO_DIR}"    && info "  ${ZENTAO_DIR} ✓" || true
    rm -rf "${ZENTAO_SRC}"    && info "  ${ZENTAO_SRC} ✓" || true
    # 清理禅道数据库（需 MySQL 可达）
    mysql -h 192.168.0.102 -P 3306 -u root -p'Kd9$prL7sQ2!vzB4' -e 'DROP DATABASE IF EXISTS zendao' 2>/dev/null && info "  zendao 数据库 ✓" || true
    # 删日志（Apache + PHP 产生的）
    rm -f /var/log/php_error.log 2>/dev/null && info "  /var/log/php_error.log ✓" || true
    rm -rf /opt/httpd/logs/* 2>/dev/null && info "  /opt/httpd/logs/ ✓" || true
    # 删残留 socket/pid
    rm -f /tmp/mysql.sock /var/run/mysqld.pid 2>/dev/null || true
    # 清 Apache 配置（下次 build_php.sh 会重建）
    rm -f /opt/httpd/conf/httpd.conf 2>/dev/null && info "  httpd.conf ✓" || true
}
clean_php() {
    step "清理 PHP/Apache..."
    pkill -9 httpd 2>/dev/null || true
    [ -d "${PHP_DIR}" ]   && rm -rf "${PHP_DIR}"   && info "  ${PHP_DIR} ✓"   || true
    [ -d "${HTTPD_DIR}" ] && rm -rf "${HTTPD_DIR}" && info "  ${HTTPD_DIR} ✓" || true
}
clean_deps() {
    step "清理依赖库..."
    # libzip 完整清理（.so .a .la 头文件 pkgconfig cmake man）
    rm -f /usr/local/lib64/libzip.* /usr/local/lib/libzip.*
    rm -f /usr/local/include/zip.h /usr/local/include/zipconf.h
    rm -f /usr/local/lib/pkgconfig/libzip.pc /usr/local/lib64/pkgconfig/libzip.pc
    rm -rf /usr/local/lib/cmake/libzip /usr/local/lib64/cmake/libzip
    rm -f /usr/local/share/man/man3/libzip.3 /usr/local/share/man/man3/zip_*.3
    # oniguruma 完整清理
    rm -f /usr/local/lib64/libonig.* /usr/local/lib/libonig.*
    rm -f /usr/local/include/oniguruma.h /usr/local/include/oniggnu.h /usr/local/include/onigposix.h
    rm -f /usr/local/lib/pkgconfig/oniguruma.pc /usr/local/lib64/pkgconfig/oniguruma.pc
    rm -f /usr/local/bin/onig-config
    # jpeg + ldconfig
    [ -L /usr/lib64/libjpeg.so ] && rm -f /usr/lib64/libjpeg.so
    rm -f /etc/ld.so.conf.d/php-local.conf
    ldconfig 2>/dev/null || true
    info "  依赖库 ✓"
}
clean_cache() {
    step "清理缓存..."
    rm -rf /tmp/build-cache
    for p in httpd-2.4.62 php-8.1.27 libzip-1.10.1 onig-6.9.9; do
        rm -rf /tmp/${p} /tmp/${p}.tar.gz
    done
    rm -rf /tmp/gcc_test /tmp/zentaopms_extract
    info "  缓存 ✓"
}
clean_wwwuser() {
    step "清理 www 用户..."
    userdel www 2>/dev/null && info "  www 用户 ✓" || true
    groupdel www 2>/dev/null && info "  www 组 ✓" || true
}

echo "============================================"
echo "  精准清理"
echo "============================================"

${CLEAN_ALL}   && { clean_zentao; clean_php; clean_deps; clean_cache; clean_wwwuser; }
${CLEAN_ZENTAO} && clean_zentao
${CLEAN_PHP}   && clean_php
${CLEAN_DEPS}  && clean_deps
${CLEAN_CACHE} && clean_cache
${CLEAN_USER}  && clean_wwwuser

echo ""
echo "============================================"
echo "  清理完成"
echo "============================================"
