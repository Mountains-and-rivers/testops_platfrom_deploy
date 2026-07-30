#!/bin/bash
# ============================================================
# Jenkins Docker 入口脚本
# 首次启动: 生成初始密码 → 配置更新中心镜像 → 启动 Jenkins
#
# 环境变量:
#   JENKINS_UC          更新中心 URL（默认清华镜像）
#   JENKINS_UC_DOWNLOAD  插件下载 URL（默认清华镜像）
#   JENKINS_SETUP_WIZARD 首次启动向导（默认 true，false=跳过）
#   JENKINS_PROXY        HTTP 代理 host:port（可选）
#   JAVA_OPTS            JVM 参数
# ============================================================
set -eo pipefail

JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_WAR="${JENKINS_WAR:-/usr/share/jenkins/jenkins.war}"
HTTP_PORT="${HTTP_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"
JAVA_OPTS="${JAVA_OPTS:--Xms1024m -Xmx2048m -XX:+UseG1GC -XX:MaxGCPauseMillis=200}"

# 国内更新中心镜像默认值（环境变量可覆盖）
JENKINS_UC="${JENKINS_UC:-https://mirrors.tuna.tsinghua.edu.cn/jenkins/updates/update-center.json}"
JENKINS_UC_DOWNLOAD="${JENKINS_UC_DOWNLOAD:-https://mirrors.tuna.tsinghua.edu.cn/jenkins/download}"

echo ">>> Jenkins v${JENKINS_VERSION} 容器启动"
echo ">>> JENKINS_HOME:     ${JENKINS_HOME}"
echo ">>> HTTP_PORT:        ${HTTP_PORT}"
echo ">>> JENKINS_UC:       ${JENKINS_UC}"
echo ">>> JENKINS_UC_DOWNLOAD: ${JENKINS_UC_DOWNLOAD}"

# 首次启动提示
if [ ! -f "${JENKINS_HOME}/config.xml" ]; then
    echo ">>> 首次启动 — 初始化数据目录..."

    # 创建 init.groovy.d 启动脚本（配置更新中心镜像）
    mkdir -p "${JENKINS_HOME}/init.groovy.d"
    cat > "${JENKINS_HOME}/init.groovy.d/update-center-mirror.groovy" << 'GROOVYEOF'
import hudson.model.UpdateSite
import jenkins.model.Jenkins

// 更新中心镜像（国内环境加速插件下载）
// 优先级: 环境变量 JENKINS_UC → 系统属性 → 清华镜像
def mirrorUrl = System.getenv('JENKINS_UC') ?:
                System.getProperty('hudson.model.UpdateCenter.updateCenterUrl') ?:
                'https://mirrors.tuna.tsinghua.edu.cn/jenkins/updates/update-center.json'

def jenkins = Jenkins.getInstanceOrNull()
if (jenkins != null) {
    def uc = jenkins.getUpdateCenter()
    def currentUrl = uc.getSite('default')?.getUrl()?.toString() ?: ''
    if (currentUrl.isEmpty() || currentUrl.contains('updates.jenkins.io')) {
        println "[init.groovy] 设置更新中心镜像: ${mirrorUrl}"
        try {
            // 创建新的 UpdateSite 并替换 default
            def newSite = new UpdateSite('default', mirrorUrl)
            def sites = uc.getSites()
            sites.removeIf { it.getId() == 'default' }
            sites.add(newSite)
            println "[init.groovy] 更新中心镜像设置成功"
        } catch (Exception e) {
            println "[init.groovy] 更新中心镜像设置失败: ${e.message}"
        }
    } else {
        println "[init.groovy] 更新中心已有自定义 URL: ${currentUrl}"
    }
}
GROOVYEOF
    echo ">>> init.groovy.d 更新中心镜像脚本已创建"
fi

# 构建启动参数
JAVA_OPTS="${JAVA_OPTS} -Djava.awt.headless=true"
JAVA_OPTS="${JAVA_OPTS} -Duser.timezone=${TZ:-Asia/Shanghai}"
# runSetupWizard: 设为 false 可跳过初始化向导（CI/自动化场景）
JAVA_OPTS="${JAVA_OPTS} -Djenkins.install.runSetupWizard=${JENKINS_SETUP_WIZARD:-true}"
JAVA_OPTS="${JAVA_OPTS} -Dhudson.model.DirectoryBrowserSupport.CSP=sandbox"

# 更新中心 URL（同时设置系统属性作为备用）
JAVA_OPTS="${JAVA_OPTS} -Dhudson.model.UpdateCenter.updateCenterUrl=${JENKINS_UC}"

# HTTP 代理（可选）
if [ -n "${JENKINS_PROXY:-}" ]; then
    PROXY_HOST=$(echo "${JENKINS_PROXY}" | cut -d: -f1)
    PROXY_PORT=$(echo "${JENKINS_PROXY}" | cut -d: -f2)
    JAVA_OPTS="${JAVA_OPTS} -Dhttp.proxyHost=${PROXY_HOST} -Dhttp.proxyPort=${PROXY_PORT}"
    JAVA_OPTS="${JAVA_OPTS} -Dhttps.proxyHost=${PROXY_HOST} -Dhttps.proxyPort=${PROXY_PORT}"
    echo ">>> HTTP 代理: ${JENKINS_PROXY}"
fi

echo ">>> 启动 Jenkins..."
exec java ${JAVA_OPTS} \
    -jar "${JENKINS_WAR}" \
    --httpPort="${HTTP_PORT}" \
    --httpListenAddress=0.0.0.0
