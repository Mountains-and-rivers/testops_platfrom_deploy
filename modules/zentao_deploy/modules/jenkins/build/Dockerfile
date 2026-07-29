# ============================================================
# Jenkins 多阶段 Docker 镜像（源码编译 + 运行时）
#
# 构建: docker build -t jenkins:2.479.1 .
# 运行: docker run -d -p 8080:8080 -p 50000:50000 \
#         -v jenkins_home:/var/lib/jenkins jenkins:2.479.1
# ============================================================

# ─── Stage 1: 源码编译 ────────────────────────────────────
FROM centos:stream9 AS builder

ARG JENKINS_VERSION=2.479.1
ARG JDK_VERSION=17
ARG MAVEN_VERSION=3.9.16

# 阿里云镜像源
COPY centos.repo /etc/yum.repos.d/centos.repo 2>/dev/null || true
RUN if [ -f /etc/yum.repos.d/centos.repo ]; then \
        sed -i 's|mirrorlist=|#mirrorlist=|g; s|#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g' /etc/yum.repos.d/centos.repo 2>/dev/null || true; \
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

# Maven 阿里云镜像
RUN mkdir -p /root/.m2 \
    && echo '<?xml version="1.0"?><settings><mirrors><mirror><id>aliyun</id><mirrorOf>central</mirrorOf><url>https://maven.aliyun.com/repository/public</url></mirror></mirrors></settings>' > /root/.m2/settings.xml

# 拉取源码 + 编译
RUN git clone --depth 1 --branch jenkins-${JENKINS_VERSION} \
        https://github.com/jenkinsci/jenkins.git /tmp/jenkins-src \
    && cd /tmp/jenkins-src \
    && mvn -pl war -am package \
        -DskipTests -Dmaven.test.skip=true \
        -Dmaven.javadoc.skip=true -Dspotbugs.skip=true \
        --batch-mode --no-transfer-progress -q \
    && cp war/target/jenkins.war /tmp/jenkins.war \
    && cd / && rm -rf /tmp/jenkins-src /root/.m2

# ─── Stage 2: 运行时 ──────────────────────────────────────
FROM centos:stream9

ARG JENKINS_VERSION=2.479.1
ARG JDK_VERSION=17

LABEL maintainer="testops" \
      org.opencontainers.image.title="Jenkins" \
      org.opencontainers.image.version="${JENKINS_VERSION}" \
      org.opencontainers.image.description="Jenkins CI Server (built from source)"

# 阿里云镜像源
COPY centos.repo /etc/yum.repos.d/centos.repo 2>/dev/null || true

# 仅安装 JRE (headless) + 必要运行时
RUN dnf install -y --setopt=tsflags=nodocs \
        java-${JDK_VERSION}-openjdk-headless \
        tzdata shadow-utils curl gzip findutils \
    && dnf clean all && rm -rf /var/cache/dnf \
    && rm -f /etc/yum.repos.d/centos.repo 2>/dev/null || true

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
