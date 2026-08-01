# ============================================================
# Wiki.js — 全量编译 Dockerfile（源码→镜像）
# 用法: docker build -f build/Dockerfile -t wiki:latest .
# ============================================================
FROM quay.io/centos/centos:stream9 AS builder

# 安装 Node.js 22.x
ARG NODE_VERSION=22.20.0
COPY build/node-v${NODE_VERSION}-linux-x64.tar.xz /tmp/ 2>/dev/null || true
RUN if [ -f /tmp/node-v${NODE_VERSION}-linux-x64.tar.xz ]; then \
        tar -xJf /tmp/node-v${NODE_VERSION}-linux-x64.tar.xz -C /usr/local --strip-components=1; \
    else \
        curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz \
        | tar -xJf - -C /usr/local --strip-components=1; \
    fi

# 源码
COPY . /tmp/wiki-src
WORKDIR /tmp/wiki-src

RUN npm config set registry https://registry.npmmirror.com && \
    npm install --production && \
    npm run build

# ── 运行阶段 ──
FROM quay.io/centos/centos:stream9

RUN dnf install -y glibc-langpack-en && dnf clean all
ENV LANG=en_US.UTF-8

COPY --from=builder /usr/local/bin/node /usr/local/bin/
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/bin/node /usr/bin/node && \
    ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

COPY --from=builder /tmp/wiki-src /opt/wiki
WORKDIR /opt/wiki

RUN groupadd -r wiki && useradd -r -g wiki -s /bin/false wiki && \
    mkdir -p /data/wiki /var/log/wiki && \
    chown -R wiki:wiki /opt/wiki /data/wiki /var/log/wiki

COPY build/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3000
USER wiki
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "server"]
