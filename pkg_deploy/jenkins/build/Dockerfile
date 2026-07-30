# ============================================================
# Jenkins 多阶段 Docker 镜像（源码编译 + 运行时）
#
# 构建: bash build_image.sh                 # Docker 内全量编译
#       bash build_image.sh --prebuilt      # 使用预编译 WAR
# 运行: docker run -d -p 8080:8080 -p 50000:50000 \
#         -v jenkins_home:/var/lib/jenkins jenkins:2.479.1
# ============================================================

# ─── Stage 1: 源码编译 ────────────────────────────────────
FROM centos:stream9 AS builder

ARG JENKINS_VERSION=2.479.1
ARG JDK_VERSION=21
ARG MAVEN_VERSION=3.9.16

# 阿里云镜像源（build_image.sh 保证 centos.repo 始终存在，为空时跳过）
COPY centos.repo /etc/yum.repos.d/centos.repo
RUN if [ -s /etc/yum.repos.d/centos.repo ]; then \
        sed -i 's|mirrorlist=|#mirrorlist=|g; s|#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g' /etc/yum.repos.d/centos.repo; \
    fi

# JDK + Maven + 编译工具
RUN dnf install -y --setopt=tsflags=nodocs \
        java-${JDK_VERSION}-openjdk-devel git wget unzip findutils \
    && dnf clean all && rm -rf /var/cache/dnf

# Maven
RUN MAVEN_URL="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    && wget -q -O /tmp/maven.tar.gz "${MAVEN_URL}" \
    && tar -xzf /tmp/maven.tar.gz -C /opt \
    && ln -s /opt/apache-maven-${MAVEN_VERSION} /opt/maven \
    && rm /tmp/maven.tar.gz

ENV JAVA_HOME=/usr/lib/jvm/java-${JDK_VERSION}-openjdk \
    MAVEN_HOME=/opt/maven \
    PATH=/opt/maven/bin:/usr/lib/jvm/java-${JDK_VERSION}-openjdk/bin:${PATH}

# Maven settings（双镜像加速）
# central → aliyun | repo.jenkins-ci.org → huawei（华为云代理了 Jenkins 仓库）
RUN mkdir -p /root/.m2 \
    && echo '<?xml version="1.0" encoding="UTF-8"?><settings><mirrors><mirror><id>aliyun-maven</id><mirrorOf>central</mirrorOf><name>Aliyun Maven</name><url>https://maven.aliyun.com/repository/public</url></mirror><mirror><id>huawei-jenkins</id><mirrorOf>repo.jenkins-ci.org</mirrorOf><name>Huawei Maven</name><url>https://repo.huaweicloud.com/repository/maven/</url></mirror></mirrors><profiles><profile><id>china-mirrors</id><repositories><repository><id>central</id><url>https://maven.aliyun.com/repository/public</url><releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></repository><repository><id>repo.jenkins-ci.org</id><url>https://repo.huaweicloud.com/repository/maven/</url><releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></repository></repositories><pluginRepositories><pluginRepository><id>central</id><url>https://maven.aliyun.com/repository/public</url><releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></pluginRepository><pluginRepository><id>repo.jenkins-ci.org</id><url>https://repo.huaweicloud.com/repository/maven/</url><releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></pluginRepository></pluginRepositories></profile></profiles><activeProfiles><activeProfile>china-mirrors</activeProfile></activeProfiles></settings>' > /root/.m2/settings.xml

# 源码（由 build_image.sh 复制本地 jenkins.zip 到构建上下文）
COPY jenkins.zip /tmp/
RUN unzip -q /tmp/jenkins.zip -d /tmp/jenkins-src \
    && rm /tmp/jenkins.zip \
    # 先清理 .git（否则 rmdir 时目录非空，顶层剥不掉）
    && find /tmp/jenkins-src -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true \
    && find /tmp/jenkins-src -name ".github" -type d -exec rm -rf {} + 2>/dev/null || true \
    # GitHub zip 包有一层外层目录，自动剥掉
    && TOP=$(ls -1 /tmp/jenkins-src | head -1) \
    && if [ -n "${TOP}" ] && [ -d "/tmp/jenkins-src/${TOP}" ] && [ "$(ls -A /tmp/jenkins-src | wc -l)" -eq 1 ]; then \
        mv /tmp/jenkins-src/${TOP}/* /tmp/jenkins-src/; \
        mv /tmp/jenkins-src/${TOP}/.[!.]* /tmp/jenkins-src/ 2>/dev/null || true; \
        rmdir /tmp/jenkins-src/${TOP}; \
    fi \
    # 移除 test 模块（集成测试，需要 maven-hpi-plugin 等 Jenkins 私有插件，编译 WAR 不需要）
    && rm -rf /tmp/jenkins-src/test \
    && sed -i 's/<module>test<\/module>//g' /tmp/jenkins-src/pom.xml \
    # 修复 Windows CRLF（zip 打包可能带入）
    && find /tmp/jenkins-src -type f ! -name '*.jar' ! -name '*.gz' ! -name '*.zip' -exec sed -i 's/\r$//' {} \; 2>/dev/null || true

# Node.js tarball → Maven 本地仓库缓存（避免 frontend-maven-plugin 在线下载失败）
# build_image.sh 复制原始 node-v*.tar.gz 到构建上下文；不存在时为 node-v0.0.0-linux-x64.tar.gz 空占位
COPY node-v*-linux-x64.tar.gz /tmp/
RUN NODE_TAR=$(ls /tmp/node-v*-linux-x64.tar.gz 2>/dev/null | head -1) \
    && if [ -s "${NODE_TAR}" ]; then \
        NODE_VER=$(echo "$(basename "${NODE_TAR}")" | sed 's/node-v\([0-9.]*\)-.*/\1/') \
        && echo "Node v${NODE_VER}: 预填充 Maven 缓存（跳过 download）" \
        && mkdir -p /root/.m2/repository/com/github/eirslett/node/${NODE_VER} \
        && cp "${NODE_TAR}" /root/.m2/repository/com/github/eirslett/node/${NODE_VER}/node-${NODE_VER}-linux-x64.tar.gz; \
    else \
        echo "Node: 未提供离线包，Docker 内将尝试在线下载"; \
    fi \
    && rm -f /tmp/node-v*-linux-x64.tar.gz

# 编译（-Pquick-build 官方快速构建 profile）
# BuildKit cache mount 持久化 /root/.m2，避免重复下载依赖
# 三级退化重试：在线 clean install → 在线 install → 离线 install -o
# 去掉 --no-transfer-progress，保留 --batch-mode，让用户能看到进度
RUN --mount=type=cache,target=/root/.m2,id=maven-repo \
    cd /tmp/jenkins-src \
    && MVN_OPTS="-pl war,bom -am \
        -Pquick-build \
        -Dmaven.buildNumber.skip=true \
        -Dcheckstyle.skip=true \
        -Dmaven.repo.local=/root/.m2 \
        -Djenkins.version=${JENKINS_VERSION} \
        -Dmaven.wagon.http.retryHandler.count=3 \
        -Dmaven.wagon.httpconnectionManager.ttlSeconds=30 \
        -Dmaven.wagon.rto=30000 \
        --batch-mode" \
    && echo "============================================" \
    && echo ">>> (1/3) mvn clean install（在线）" \
    && echo "============================================" \
    && (mvn ${MVN_OPTS} clean install && echo ">>> (1/3) 成功") \
    || (echo ">>> (1/3) 失败，5s 后重试..." && sleep 5 \
        && echo "============================================" \
        && echo ">>> (2/3) mvn install（在线，跳过 clean）" \
        && echo "============================================" \
        && (mvn ${MVN_OPTS} install && echo ">>> (2/3) 成功") \
        || (echo ">>> (2/3) 失败，5s 后重试..." && sleep 5 \
            && echo "============================================" \
            && echo ">>> (3/3) mvn install -o（离线，限已有缓存）" \
            && echo "============================================" \
            && (mvn ${MVN_OPTS} install -o && echo ">>> (3/3) 成功") \
            || (echo ">>> 3 次全部失败" && exit 1) \
           ) \
       ) \
    && echo ">>> Maven 编译完成" \
    && cp war/target/jenkins.war /tmp/jenkins.war \
    && cd / && rm -rf /tmp/jenkins-src

# ─── Stage 2: 运行时 ──────────────────────────────────────
FROM centos:stream9

ARG JENKINS_VERSION=2.479.1
ARG JDK_VERSION=21

LABEL maintainer="testops" \
      org.opencontainers.image.title="Jenkins" \
      org.opencontainers.image.version="${JENKINS_VERSION}" \
      org.opencontainers.image.description="Jenkins CI Server (built from source)"

# 阿里云镜像源（build_image.sh 保证 centos.repo 始终存在）
COPY centos.repo /etc/yum.repos.d/centos.repo
RUN if [ -s /etc/yum.repos.d/centos.repo ]; then \
        sed -i 's|mirrorlist=|#mirrorlist=|g; s|#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g' /etc/yum.repos.d/centos.repo; \
    fi

# 仅安装 JRE (headless) + 必要运行时
RUN dnf install -y --setopt=tsflags=nodocs \
        java-${JDK_VERSION}-openjdk-headless \
        tzdata shadow-utils gzip findutils \
    && dnf clean all && rm -rf /var/cache/dnf \
    && rm -f /etc/yum.repos.d/centos.repo

ENV JAVA_HOME=/usr/lib/jvm/jre-${JDK_VERSION}-openjdk \
    JENKINS_HOME=/var/lib/jenkins \
    JENKINS_VERSION=${JENKINS_VERSION} \
    LANG=en_US.UTF-8 \
    TZ=Asia/Shanghai

# 从 builder 复制 WAR
COPY --from=builder /tmp/jenkins.war /usr/share/jenkins/jenkins.war

# 创建 jenkins 用户
RUN groupadd -f -r jenkins \
    && useradd -r -g jenkins -d ${JENKINS_HOME} -s /bin/bash -c "Jenkins" jenkins \
    && mkdir -p ${JENKINS_HOME} /usr/share/jenkins \
    && chown -R jenkins:jenkins ${JENKINS_HOME} /usr/share/jenkins

# 入口脚本
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 声明卷
VOLUME ${JENKINS_HOME}

# 端口
EXPOSE 8080 50000

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD curl -sf http://localhost:8080/login || exit 1

USER jenkins
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
