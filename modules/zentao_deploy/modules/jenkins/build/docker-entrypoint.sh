#!/bin/bash
# ============================================================
# Jenkins Docker 入口脚本
# 首次启动: 生成初始密码 → 启动 Jenkins
# ============================================================
set -eo pipefail

JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_WAR="${JENKINS_WAR:-/usr/share/jenkins/jenkins.war}"
HTTP_PORT="${HTTP_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"
JAVA_OPTS="${JAVA_OPTS:--Xms1024m -Xmx2048m -XX:+UseG1GC -XX:MaxGCPauseMillis=200}"

echo ">>> Jenkins v${JENKINS_VERSION} 容器启动"
echo ">>> JENKINS_HOME: ${JENKINS_HOME}"
echo ">>> HTTP_PORT:    ${HTTP_PORT}"

# 首次启动提示
if [ ! -f "${JENKINS_HOME}/config.xml" ]; then
    echo ">>> 首次启动 — 初始化数据目录..."
fi

# 构建启动参数
JAVA_OPTS="${JAVA_OPTS} -Djava.awt.headless=true"
JAVA_OPTS="${JAVA_OPTS} -Duser.timezone=${TZ:-Asia/Shanghai}"
JAVA_OPTS="${JAVA_OPTS} -Djenkins.install.runSetupWizard=false"
JAVA_OPTS="${JAVA_OPTS} -Dhudson.model.DirectoryBrowserSupport.CSP=sandbox"

echo ">>> 启动 Jenkins..."
exec java ${JAVA_OPTS} \
    -jar "${JENKINS_WAR}" \
    --httpPort="${HTTP_PORT}" \
    --httpListenAddress=0.0.0.0
