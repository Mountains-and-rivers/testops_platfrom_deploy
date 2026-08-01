# ============================================================
# MeterSphere v3.x — 全量编译 Dockerfile（源码→镜像）
# 用法: docker build -f build/Dockerfile -t metersphere:latest .
# ============================================================
FROM quay.io/centos/centos:stream9 AS builder

# JDK 17
ARG JDK_VERSION=17.0.13
ARG JDK_TAR=OpenJDK17U-jdk_x64_linux_hotspot_${JDK_VERSION}_11.tar.gz
COPY build/${JDK_TAR} /tmp/ 2>/dev/null || true
RUN if [ -f /tmp/${JDK_TAR} ]; then \
        tar -xzf /tmp/${JDK_TAR} -C /opt --strip-components=1 && mkdir -p /opt/jdk17 && cp -a /opt/* /opt/jdk17/ 2>/dev/null || true; \
    else \
        curl -fsSL https://github.com/adoptium/temurin17-binaries/releases/download/jdk-${JDK_VERSION}%2B11/${JDK_TAR} \
        | tar -xzf - -C /opt/jdk17 --strip-components=1; \
    fi

# Maven 3.9
ARG MAVEN_VERSION=3.9.16
COPY build/apache-maven-${MAVEN_VERSION}-bin.tar.gz /tmp/ 2>/dev/null || true
RUN if [ -f /tmp/apache-maven-${MAVEN_VERSION}-bin.tar.gz ]; then \
        tar -xzf /tmp/apache-maven-${MAVEN_VERSION}-bin.tar.gz -C /opt --strip-components=1 && mkdir -p /opt/maven && cp -a /opt/* /opt/maven/ 2>/dev/null || true; \
    else \
        curl -fsSL https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz \
        | tar -xzf - -C /opt/maven --strip-components=1; \
    fi

ENV JAVA_HOME=/opt/jdk17 MAVEN_HOME=/opt/maven
ENV PATH=${JAVA_HOME}/bin:${MAVEN_HOME}/bin:${PATH}

COPY . /tmp/ms-src
WORKDIR /tmp/ms-src

RUN mvn clean package -DskipTests -Dmaven.test.skip=true -Pprod -q || \
    mvn clean package -DskipTests -Dmaven.test.skip=true -q

# ── 运行阶段 ──
FROM quay.io/centos/centos:stream9

COPY --from=builder /opt/jdk17 /opt/jdk17
ENV JAVA_HOME=/opt/jdk17 PATH=/opt/jdk17/bin:${PATH}

RUN groupadd -r metersphere && useradd -r -g metersphere -s /bin/false metersphere && \
    mkdir -p /opt/metersphere /data/metersphere /var/log/metersphere

COPY --from=builder /tmp/ms-src/*/target/metersphere*.jar /opt/metersphere/
RUN chown -R metersphere:metersphere /opt/metersphere /data/metersphere /var/log/metersphere

COPY build/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8081
USER metersphere
ENTRYPOINT ["docker-entrypoint.sh"]
