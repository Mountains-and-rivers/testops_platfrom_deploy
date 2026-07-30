# ============================================================
# Stage 1: 编译阶段（Docker 内编译 PHP + Apache）
# ============================================================
FROM centos:stream9 AS builder

# 替换为阿里云 yum 源（国内加速）
COPY centos.repo /etc/yum.repos.d/centos.repo

RUN dnf install -y epel-release && \
    dnf config-manager --set-enabled crb 2>/dev/null || true && \
    dnf install -y --allowerasing \
        gcc gcc-c++ make autoconf libtool bison re2c pkgconfig cmake \
        libxml2-devel libpng-devel libjpeg-turbo-devel freetype-devel \
        openssl-devel curl-devel libicu-devel sqlite-devel httpd-devel wget unzip \
        redhat-rpm-config annobin gcc-plugin-annobin && \
    dnf clean all

# 从源码编译 libzip（优先本地包，不存在则下载）
COPY libzip-1.10.1.tar.gz /tmp/
RUN cd /tmp && tar xf libzip-1.10.1.tar.gz && cd libzip-1.10.1 && \
    mkdir build && cd build && cmake .. && make -j$(nproc) && make install && \
    rm -rf /tmp/libzip-1.10.1*

# 从源码编译 oniguruma（优先本地包，不存在则下载）
COPY onig-6.9.9.tar.gz /tmp/
RUN cd /tmp && tar xf onig-6.9.9.tar.gz && cd onig-6.9.9 && \
    ./configure && make -j$(nproc) && make install && ldconfig && \
    rm -rf /tmp/onig-6.9.9*
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig

COPY httpd-2.4.62.tar.gz /tmp/
RUN cd /tmp && tar -xzf httpd-2.4.62.tar.gz && cd httpd-2.4.62 && \
    ./configure --prefix=/opt/httpd \
        --enable-ssl --enable-rewrite --enable-headers \
        --enable-deflate --enable-proxy --enable-proxy-fcgi --with-mpm=prefork && \
    make -j$(nproc) && make install && rm /tmp/httpd-2.4.62.tar.gz

COPY php-8.1.27.tar.gz /tmp/
RUN cd /tmp && tar -xzf php-8.1.27.tar.gz && cd php-8.1.27 && \
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
    make -j$(nproc) && make install && rm /tmp/php-8.1.27.tar.gz

RUN mkdir -p /opt/php/etc/conf.d && \
    { \
        echo '[PHP]'; \
        echo 'memory_limit = 512M'; \
        echo 'post_max_size = 100M'; \
        echo 'upload_max_filesize = 100M'; \
        echo 'max_execution_time = 300'; \
        echo 'date.timezone = Asia/Shanghai'; \
        echo 'opcache.enable = 1'; \
        echo 'opcache.memory_consumption = 256'; \
    } > /opt/php/etc/conf.d/zentao.ini && \
    cp /opt/httpd/modules/libphp.so /opt/httpd/modules/ 2>/dev/null || true && \
    strip /opt/php/bin/php /opt/httpd/bin/httpd /opt/httpd/modules/libphp.so 2>/dev/null || true && \
    rm -rf /tmp/*

# ============================================================
# Stage 2: 运行镜像
# ============================================================
FROM centos:stream9

# 替换为阿里云 yum 源（国内加速）
COPY centos.repo /etc/yum.repos.d/centos.repo

RUN dnf install -y epel-release && \
    dnf config-manager --set-enabled crb 2>/dev/null || true && \
    dnf install -y --allowerasing \
        libxml2 libpng libjpeg-turbo freetype libzip \
        openssl curl libicu oniguruma mysql apr apr-util && \
    dnf clean all

COPY --from=builder /opt/php /opt/php
COPY --from=builder /opt/httpd /opt/httpd

RUN groupadd -r -g 1000 www && useradd -r -u 1000 -g www -d /var/www www && \
    mkdir -p /var/www/zentaopms && chown -R www:www /var/www/zentaopms

ARG ZENTAO_VERSION=21.2
COPY --chown=www:www source/ /var/www/zentaopms/

RUN echo 'ServerRoot /opt/httpd' > /opt/httpd/conf/httpd.conf && \
    echo 'Listen 8080' >> /opt/httpd/conf/httpd.conf && \
    echo 'User www' >> /opt/httpd/conf/httpd.conf && \
    echo 'Group www' >> /opt/httpd/conf/httpd.conf && \
    echo 'LoadModule mime_module modules/mod_mime.so' >> /opt/httpd/conf/httpd.conf && \
    echo 'LoadModule unixd_module modules/mod_unixd.so' >> /opt/httpd/conf/httpd.conf && \
    echo 'LoadModule authz_core_module modules/mod_authz_core.so' >> /opt/httpd/conf/httpd.conf && \
    echo 'LoadModule authz_host_module modules/mod_authz_host.so' >> /opt/httpd/conf/httpd.conf && \
    echo 'LoadModule rewrite_module modules/mod_rewrite.so' >> /opt/httpd/conf/httpd.conf && \
    echo 'LoadModule dir_module modules/mod_dir.so' >> /opt/httpd/conf/httpd.conf && \
    echo 'LoadModule php_module modules/libphp.so' >> /opt/httpd/conf/httpd.conf && \
    echo 'TypesConfig conf/mime.types' >> /opt/httpd/conf/httpd.conf && \
    echo 'AddType text/javascript .js .mjs' >> /opt/httpd/conf/httpd.conf && \
    echo 'DocumentRoot /var/www/zentaopms/www' >> /opt/httpd/conf/httpd.conf && \
    echo '<Directory />' >> /opt/httpd/conf/httpd.conf && \
    echo '    AllowOverride none' >> /opt/httpd/conf/httpd.conf && \
    echo '    Require all denied' >> /opt/httpd/conf/httpd.conf && \
    echo '</Directory>' >> /opt/httpd/conf/httpd.conf && \
    echo '<Directory /var/www/zentaopms/www>' >> /opt/httpd/conf/httpd.conf && \
    echo '    Options FollowSymLinks' >> /opt/httpd/conf/httpd.conf && \
    echo '    AllowOverride All' >> /opt/httpd/conf/httpd.conf && \
    echo '    Require all granted' >> /opt/httpd/conf/httpd.conf && \
    echo '</Directory>' >> /opt/httpd/conf/httpd.conf && \
    echo '<FilesMatch \\.php$>' >> /opt/httpd/conf/httpd.conf && \
    echo '  SetHandler application/x-httpd-php' >> /opt/httpd/conf/httpd.conf && \
    echo '</FilesMatch>' >> /opt/httpd/conf/httpd.conf && \
    echo 'DirectoryIndex index.php index.html' >> /opt/httpd/conf/httpd.conf && \
    echo 'ServerName localhost' >> /opt/httpd/conf/httpd.conf

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /opt/httpd/logs && \
    chown -R www:www /var/www/zentaopms/www/data /var/www/zentaopms/tmp \
        /var/www/zentaopms/log /opt/httpd/logs 2>/dev/null || true

ENV PATH=/opt/php/bin:/opt/httpd/bin:$PATH

EXPOSE 8080
USER www:www
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["httpd", "-D", "FOREGROUND"]
