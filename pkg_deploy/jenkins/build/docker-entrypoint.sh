#!/bin/bash
# ============================================================
# Jenkins Docker 入口脚本
# 首次启动: 生成初始密码 → 创建 init.groovy.d → 启动 Jenkins
#
# 环境变量:
#   JENKINS_UC           更新中心 URL（默认使用官方，国内镜像不提供 update-center.json）
#   JENKINS_PLUGIN_MIRROR 插件下载镜像（默认 USTC，用于 jenkins-plugin-cli 离线场景）
#   JENKINS_SETUP_WIZARD  首次启动向导（默认 true，false=跳过）
#   JENKINS_PROXY         HTTP 代理 host:port（可选）
#   JAVA_OPTS             JVM 参数
# ============================================================
set -eo pipefail

JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_WAR="${JENKINS_WAR:-/usr/share/jenkins/jenkins.war}"
HTTP_PORT="${HTTP_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"
JAVA_OPTS="${JAVA_OPTS:--Xms1024m -Xmx2048m -XX:+UseG1GC -XX:MaxGCPauseMillis=200}"

# 插件下载镜像（USTC 实测可达，用于 jenkins-plugin-cli / 手动离线下载）
JENKINS_PLUGIN_MIRROR="${JENKINS_PLUGIN_MIRROR:-https://mirrors.ustc.edu.cn/jenkins/plugins}"

echo ">>> Jenkins v${JENKINS_VERSION} 容器启动"
echo ">>> JENKINS_HOME:         ${JENKINS_HOME}"
echo ">>> HTTP_PORT:            ${HTTP_PORT}"
echo ">>> JENKINS_PLUGIN_MIRROR: ${JENKINS_PLUGIN_MIRROR}"

# 首次启动提示
if [ ! -f "${JENKINS_HOME}/config.xml" ]; then
    echo ">>> 首次启动 — 初始化数据目录..."

    # ── 插件预下载（从国内镜像加速）────────────────
    # 确保 JENKINS_PLUGIN_MIRROR 配置了镜像后，首次启动自动预下载建议插件
    # 环境变量:
    #   JENKINS_PLUGIN_MIRROR      插件下载镜像（默认 USTC，设空跳过预下载）
    #   JENKINS_PREINSTALL_PLUGINS  要预下载的插件列表（逗号分隔，默认使用建议列表）
    PREINSTALL_SCRIPT="/usr/local/bin/preinstall_plugins.sh"
    if [ -n "${JENKINS_PLUGIN_MIRROR:-}" ] && [ -s "${PREINSTALL_SCRIPT}" ] && [ -x "${PREINSTALL_SCRIPT}" ]; then
        echo ">>> 预下载插件: ${JENKINS_PLUGIN_MIRROR}"

        # 选择镜像名
        _p_mirror="ustc"
        case "${JENKINS_PLUGIN_MIRROR}" in
            *tuna*|*tsinghua*) _p_mirror="tsinghua" ;;
        esac

        _p_opts=""
        [ -n "${JENKINS_PREINSTALL_PLUGINS:-}" ] && _p_opts="--plugin-list ${JENKINS_PREINSTALL_PLUGINS}"

        if MIRROR="${_p_mirror}" JENKINS_PLUGIN_DIR="${JENKINS_HOME}/plugins" \
            bash "${PREINSTALL_SCRIPT}" ${_p_opts} 2>&1; then
            echo ">>> 插件预下载完成"
        else
            echo ">>> 警告: 插件预下载部分失败，Jenkins 启动后会重试"
        fi
    fi

    # ── 创建 init.groovy.d 启动脚本（更新中心健康检查）────────────────
    mkdir -p "${JENKINS_HOME}/init.groovy.d"
    cat > "${JENKINS_HOME}/init.groovy.d/update-center-mirror.groovy" << 'GROOVYEOF'
import hudson.model.UpdateSite
import jenkins.model.Jenkins

// 更新中心健康检查 & 错误恢复
// 国内镜像（USTC/清华/华为）只镜像 plugins/，不提供 update-center.json
// 此脚本检测并恢复被错误配置的更新中心 URL
def jenkins = Jenkins.getInstanceOrNull()
if (jenkins != null) {
    def uc = jenkins.getUpdateCenter()
    def currentUrl = uc.getSite('default')?.getUrl()?.toString() ?: ''
    println "[init.groovy] Current update center: ${currentUrl}"

    if (currentUrl.contains('tuna.tsinghua.edu.cn') ||
        currentUrl.contains('ustc.edu.cn') ||
        currentUrl.contains('huaweicloud.com')) {
        println "[init.groovy] WARNING: Mirror does not host update-center.json, reverting to official"
        def officialSite = new UpdateSite('default', 'https://updates.jenkins.io/update-center.json')
        def sites = uc.getSites()
        sites.removeIf { it.getId() == 'default' }
        sites.add(officialSite)
        println "[init.groovy] Reverted to: https://updates.jenkins.io/update-center.json"
    }
}
GROOVYEOF
    echo ">>> init.groovy.d 更新中心健康检查脚本已创建"
fi

# 构建启动参数
JAVA_OPTS="${JAVA_OPTS} -Djava.awt.headless=true"
JAVA_OPTS="${JAVA_OPTS} -Duser.timezone=${TZ:-Asia/Shanghai}"
# runSetupWizard: 设为 false 可跳过初始化向导（CI/自动化场景）
JAVA_OPTS="${JAVA_OPTS} -Djenkins.install.runSetupWizard=${JENKINS_SETUP_WIZARD:-true}"
JAVA_OPTS="${JAVA_OPTS} -Dhudson.model.DirectoryBrowserSupport.CSP=sandbox"

# 自定义更新中心 URL（仅当用户显式设置时生效）
if [ -n "${JENKINS_UC:-}" ]; then
    JAVA_OPTS="${JAVA_OPTS} -Dhudson.model.UpdateCenter.updateCenterUrl=${JENKINS_UC}"
    echo ">>> JENKINS_UC: ${JENKINS_UC}"
fi

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
