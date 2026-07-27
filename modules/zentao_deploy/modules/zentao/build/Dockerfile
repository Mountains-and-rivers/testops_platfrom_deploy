# ============================================================
# Stage 1: CentOS Stream 9 源码编译 PHP 8.1 + Apache 2.4
# 严格遵循官方部署规范: https://www.zentao.net/book/zentaopms
# ============================================================
FROM centos:stream9 AS builder

LABEL maintainer="testops" \
      description="ZenTao Open Source Edition v21.2 — Custom Build from Source"

# ---- 1. 安装编译期依赖（仅 yum 源，无第三方工具） ----
RUN dnf install -y epel-release && \
    dnf install -y \
        gcc gcc-c++ make autoconf libtool bison re2c pkgconfig \
        libxml2-devel libpng-devel libjpeg-turbo-devel freetype-devel \
        libzip-devel oniguruma-devel openssl-devel curl-devel libicu-devel \
        sqlite-devel httpd-devel wget unzip && \
    dnf clean all

# ---- 2. 编译 Apache httpd 2.4 ----
ENV HTTPD_VERSION=2.4.62
RUN cd /tmp && \
    wget -q https://archive.apache.org/dist/httpd/httpd-${HTTPD_VERSION}.tar.gz && \
    tar -xzf httpd-${HTTPD_VERSION}.tar.gz && rm httpd-${HTTPD_VERSION}.tar.gz && \
    cd httpd-${HTTPD_VERSION} && \
    ./configure --prefix=/opt/httpd \
        --enable-ssl --enable-rewrite --enable-headers \
        --enable-deflate --enable-proxy --enable-proxy-fcgi \
        --with-mpm=prefork && \
    make -j$(nproc) && make install

# ---- 3. 编译 PHP 8.1 ----
ENV PHP_VERSION=8.1.27
RUN cd /tmp && \
    wget -q https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz && \
    tar -xzf php-${PHP_VERSION}.tar.gz && rm php-${PHP_VERSION}.tar.gz && \
    cd php-${PHP_VERSION} && \
    ./configure \
        --prefix=/opt/php \
        --with-apxs2=/opt/httpd/bin/apxs \
        --with-config-file-path=/opt/php/etc \
        --with-config-file-scan-dir=/opt/php/etc/conf.d \
        --enable-mbstring --enable-xml --enable-dom \
        --enable-fileinfo --enable-intl --enable-bcmath \
        --enable-opcache --enable-exif \
        --with-zip --with-curl --with-openssl \
        --with-pdo-mysql=mysqlnd --with-mysqli=mysqlnd \
        --with-freetype --with-jpeg --with-gd && \
    make -j$(nproc) && make install

# ---- 4. PHP 配置 ----
RUN mkdir -p /opt/php/etc/conf.d && \
    { \
        echo '[PHP]'; \
        echo 'memory_limit = 512M'; \
        echo 'post_max_size = 100M'; \
        echo 'upload_max_filesize = 100M'; \
        echo 'max_execution_time = 300'; \
        echo 'max_input_time = 300'; \
        echo 'date.timezone = Asia/Shanghai'; \
        echo 'opcache.enable = 1'; \
        echo 'opcache.memory_consumption = 256'; \
    } > /opt/php/etc/conf.d/zentao.ini && \
    cp /opt/php/libphp.so /opt/httpd/modules/ && \
    strip /opt/php/bin/php /opt/httpd/bin/httpd /opt/php/libphp.so 2>/dev/null || true && \
    rm -rf /tmp/*


# ============================================================
# Stage 2: 运行镜像（精简）
# ============================================================
FROM centos:stream9

# 运行期依赖
RUN dnf install -y epel-release && \
    dnf install -y libxml2 libpng libjpeg-turbo freetype libzip \
        openssl curl libicu oniguruma && \
    dnf clean all

# 复制编译产物
COPY --from=builder /opt/php /opt/php
COPY --from=builder /opt/httpd /opt/httpd

# 创建运行用户
RUN groupadd -r -g 1000 www && useradd -r -u 1000 -g www -d /var/www www && \
    mkdir -p /var/www/zentaopms && chown -R www:www /var/www/zentaopms

# 复制禅道源码
ARG ZENTAO_VERSION=21.2
COPY source/ /var/www/zentaopms/

# 配置 Apache
RUN sed -i 's|Listen 80|Listen 8080|' /opt/httpd/conf/httpd.conf && \
    sed -i 's|DocumentRoot ".*"|DocumentRoot "/var/www/zentaopms/www"|' \
        /opt/httpd/conf/httpd.conf && \
    sed -i 's|User daemon|User www|' /opt/httpd/conf/httpd.conf && \
    sed -i 's|Group daemon|Group www|' /opt/httpd/conf/httpd.conf && \
    echo 'LoadModule php_module modules/libphp.so' >> /opt/httpd/conf/httpd.conf && \
    echo '<FilesMatch \.php$>' >> /opt/httpd/conf/httpd.conf && \
    echo '  SetHandler application/x-httpd-php' >> /opt/httpd/conf/httpd.conf && \
    echo '</FilesMatch>' >> /opt/httpd/conf/httpd.conf && \
    echo 'ServerName localhost' >> /opt/httpd/conf/httpd.conf

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    chown -R www:www /var/www/zentaopms/www/data /var/www/zentaopms/tmp \
        /var/www/zentaopms/log 2>/dev/null || true

ENV PATH=/opt/php/bin:/opt/httpd/bin:$PATH \
    ZENTAO_VERSION=${ZENTAO_VERSION}

EXPOSE 8080
USER www:www
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["httpd", "-D", "FOREGROUND"]
