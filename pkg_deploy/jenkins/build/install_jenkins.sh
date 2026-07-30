#!/bin/bash
# ============================================================
# Jenkins 裸机 systemd 进程安装（企业级）
# 前置: bash build_jenkins.sh（产出 /opt/jenkins/jenkins.war）
# 用法: bash install_jenkins.sh [--force] [--port 9090]
# ============================================================

# 强制使用 bash（sh/dash 不支持 pipefail）
[ -z "${BASH_VERSION:-}" ] && exec bash "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" "$@"

set -euo pipefail
cd /tmp

# ── 参数 ─────────────────────────────────────────────────
JENKINS_VERSION="${JENKINS_VERSION:-2.479.1}"
JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_PORT="${JENKINS_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"
JENKINS_WAR="${JENKINS_WAR:-/opt/jenkins/jenkins.war}"
JENKINS_DIR="$(dirname "${JENKINS_WAR}")"
JENKINS_USER="${JENKINS_USER:-jenkins}"
JENKINS_LOG_DIR="${JENKINS_LOG_DIR:-/var/log/jenkins}"
JENKINS_RUN_DIR="${JENKINS_RUN_DIR:-/run/jenkins}"
HEAP_MIN="${HEAP_MIN:-2048m}"
HEAP_MAX="${HEAP_MAX:-4096m}"
# 更新中心 URL — 保持默认（国内镜像不提供 update-center.json）
# 仅当需要覆盖时设置，例如: JENKINS_UC=https://updates.jenkins.io/update-center.json
JENKINS_UC="${JENKINS_UC:-}"
# 插件下载镜像（jenkins-plugin-cli / 离线预下载用）
JENKINS_PLUGIN_MIRROR="${JENKINS_PLUGIN_MIRROR:-https://mirrors.ustc.edu.cn/jenkins/plugins}"
# HTTP 代理（可选，格式 host:port）
JENKINS_PROXY="${JENKINS_PROXY:-}"
FORCE=false; SKIP_FW=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --port) JENKINS_PORT="$2"; shift 2 ;;
        --skip-firewall) SKIP_FW=true; shift ;;
        *) shift ;;
    esac
done

# ── UI ──────────────────────────────────────────────────
readonly R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
info()  { echo -e "${G}[INFO]${N}  $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*"; }
step()  { echo -e "${C}[STEP]${N}  $*"; }
ok()    { echo -e "  ${G}[OK]${N} $*"; }
die()   { echo -e "\n${R}━━━━ ${BASH_SOURCE[0]}:${BASH_LINENO[0]} ━━━━${N}\n${R}  $*${N}\n"; exit 1; }
trap 'die "脚本异常退出 (exit=$?)"' ERR

[ "$(id -u)" -eq 0 ] || die "需要 root 权限"

# ── 查找 Java ──────────────────────────────────────────
_find_java() {
    for c in /opt/jdk17/bin/java /opt/jdk11/bin/java /usr/lib/jvm/java-17-openjdk/bin/java /usr/lib/jvm/java-11-openjdk/bin/java; do
        [ -x "${c}" ] && { echo "${c}"; return 0; }
    done
    command -v java 2>/dev/null && { which java; return 0; }
    return 1
}

echo ""; echo "============================================"
echo "  Jenkins ${JENKINS_VERSION} systemd 安装"
echo "============================================"; echo ""

# ── 1. 预检 ─────────────────────────────────────────────
step "[1/8] 环境检查..."

if systemctl is-active jenkins &>/dev/null 2>&1 && ! ${FORCE}; then
    info "Jenkins 已运行，跳过安装"; systemctl status jenkins --no-pager -l 2>/dev/null | head -8 || true
    echo ""; info "重装: bash install_jenkins.sh --force"; exit 0
fi
${FORCE} && warn "--force: 覆盖已有安装" && { systemctl stop jenkins 2>/dev/null || true; sleep 2; }

[ -f "${JENKINS_WAR}" ] || die "WAR 不存在: ${JENKINS_WAR}\n  请先执行: bash build_jenkins.sh"
ok "WAR: ${JENKINS_WAR} ($(du -h "${JENKINS_WAR}" | cut -f1))"

JAVA_BIN=$(_find_java) || die "Java 未安装，请先执行: bash build_jenkins.sh"
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "${JAVA_BIN}" 2>/dev/null || echo "${JAVA_BIN}")")")"

# 安装字体（Jenkins 图表/界面渲染需要，否则 Fontconfig head is null）
command -v dnf &>/dev/null && dnf install -y fontconfig dejavu-sans-fonts dejavu-serif-fonts 2>/dev/null || true
command -v apt-get &>/dev/null && apt-get install -y -qq fontconfig fonts-dejavu 2>/dev/null || true
ok "Fontconfig 已安装"
export JAVA_HOME PATH="${JAVA_HOME}/bin:${PATH}"

_jver=$("${JAVA_BIN}" -version 2>&1 | awk -F[\"_.] 'NR==1{print $2}')
ok "Java: $("${JAVA_BIN}" -version 2>&1 | head -1)"
[ "${_jver:-0}" -ge 11 ] 2>/dev/null || warn "Java ${_jver} < 11，Jenkins 2.361+ 需要 JDK 11+"

# 端口检查
ss -tlnp 2>/dev/null | grep -q ":${JENKINS_PORT} " && warn "端口 ${JENKINS_PORT} 已占用" || ok "端口: ${JENKINS_PORT} 可用"

# ── 2. 用户与目录 ──────────────────────────────────────
step "[2/8] 用户与目录..."

id "${JENKINS_USER}" &>/dev/null 2>&1 || {
    groupadd -f "${JENKINS_USER}"
    useradd -r -g "${JENKINS_USER}" -d "${JENKINS_HOME}" -s /bin/bash -c "Jenkins" "${JENKINS_USER}"
    ok "用户 ${JENKINS_USER} 已创建"
}

mkdir -p "${JENKINS_HOME}"/{workspace,jobs,plugins,users,secrets,updates,logs}
chown -R "${JENKINS_USER}:${JENKINS_USER}" "${JENKINS_HOME}"
chmod 750 "${JENKINS_HOME}"

mkdir -p "${JENKINS_LOG_DIR}" "${JENKINS_RUN_DIR}"
chown "${JENKINS_USER}:${JENKINS_USER}" "${JENKINS_LOG_DIR}" "${JENKINS_RUN_DIR}"
chmod 750 "${JENKINS_LOG_DIR}"; chmod 755 "${JENKINS_RUN_DIR}"

chown -R root:"${JENKINS_USER}" "${JENKINS_DIR}" 2>/dev/null || true
chmod 750 "${JENKINS_DIR}"
chmod 640 "${JENKINS_WAR}" 2>/dev/null || true
ok "目录权限就绪"

# ── 3. 环境配置 ────────────────────────────────────────
step "[3/8] 环境配置..."

cat > /etc/sysconfig/jenkins << SYSEOF
# Jenkins 环境变量 (install_jenkins.sh 生成)
JAVA_HOME=${JAVA_HOME}
JENKINS_HOME=${JENKINS_HOME}
HTTP_PORT=${JENKINS_PORT}
AGENT_PORT=${AGENT_PORT}
JENKINS_WAR=${JENKINS_WAR}
JENKINS_UC=${JENKINS_UC}
JENKINS_PLUGIN_MIRROR=${JENKINS_PLUGIN_MIRROR}
JENKINS_PROXY=${JENKINS_PROXY}
SYSEOF
chmod 644 /etc/sysconfig/jenkins; ok "/etc/sysconfig/jenkins"

# init.groovy.d 启动脚本：配置更新中心镜像 + 跳过首次向导
mkdir -p "${JENKINS_HOME}/init.groovy.d"
cat > "${JENKINS_HOME}/init.groovy.d/update-center-mirror.groovy" << 'GROOVYEOF'
import hudson.model.UpdateSite
import jenkins.model.Jenkins

// 更新中心健康检查 & 错误恢复
// 注意：国内镜像（USTC/清华/华为）只镜像 plugins/，不提供 update-center.json
// 此脚本检测并恢复被错误配置的更新中心 URL
def jenkins = Jenkins.getInstanceOrNull()
if (jenkins != null) {
    def uc = jenkins.getUpdateCenter()
    def currentUrl = uc.getSite('default')?.getUrl()?.toString() ?: ''
    println "[init.groovy] Current update center: ${currentUrl}"

    // 如果更新中心被错误指向国内镜像（这些镜像不提供 update-center.json），恢复官方 URL
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
chown -R "${JENKINS_USER}:${JENKINS_USER}" "${JENKINS_HOME}/init.groovy.d"
chmod 750 "${JENKINS_HOME}/init.groovy.d"
chmod 640 "${JENKINS_HOME}/init.groovy.d/"*.groovy 2>/dev/null || true
ok "init.groovy.d 更新中心镜像脚本"

# ── 3.5. 插件预下载 ────────────────────────────────────
step "[3.5/8] 插件预下载（国内镜像加速）..."

PREINSTALL_SCRIPT="${SCRIPT_DIR:-/tmp}/preinstall_plugins.sh"
if [ -f "${PREINSTALL_SCRIPT}" ]; then
    # 根据 JENKINS_PLUGIN_MIRROR 选择镜像名: ustc / tsinghua
    _plugin_mirror="ustc"
    case "${JENKINS_PLUGIN_MIRROR}" in
        *tuna*|*tsinghua*) _plugin_mirror="tsinghua" ;;
    esac
    MIRROR="${_plugin_mirror}" JENKINS_PLUGIN_DIR="${JENKINS_HOME}/plugins" \
        bash "${PREINSTALL_SCRIPT}" && \
        ok "插件预下载完成" || warn "插件预下载部分失败，Jenkins 启动后会继续尝试"
else
    warn "未找到 ${PREINSTALL_SCRIPT}，跳过插件预下载"
    info "  可将脚本置于 build/ 目录或指定路径"
fi

# ── 4. 日志轮转 ────────────────────────────────────────
step "[4/8] 日志轮转..."

cat > /etc/logrotate.d/jenkins << 'LOGE'
/var/log/jenkins/*.log {
    daily; rotate 30; size 100M; compress; delaycompress
    missingok; notifempty; copytruncate
    create 640 jenkins jenkins
}
LOGE
chmod 644 /etc/logrotate.d/jenkins; ok "日志轮转: 30天/100MB"

# ── 5. systemd 服务 ────────────────────────────────────
step "[5/8] systemd 服务..."

# JVM 参数（生产调优）
read -r -d '' JVM_OPTS << JVMEND || true
-Xms${HEAP_MIN}
-Xmx${HEAP_MAX}
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=${JENKINS_LOG_DIR}
-XX:+ExitOnOutOfMemoryError
-Xlog:gc*:file=${JENKINS_LOG_DIR}/gc.log:time,uptime:filecount=5,filesize=20M
-Djava.awt.headless=true
-Duser.timezone=Asia/Shanghai
-Djenkins.install.runSetupWizard=false
-Dhudson.model.DirectoryBrowserSupport.CSP=sandbox
JVMEND

# HTTP 代理 JVM 参数（可选）
if [ -n "${JENKINS_PROXY}" ]; then
    JVM_OPTS="${JVM_OPTS}\n-Dhttp.proxyHost=$(echo "${JENKINS_PROXY}" | cut -d: -f1)"
    JVM_OPTS="${JVM_OPTS}\n-Dhttp.proxyPort=$(echo "${JENKINS_PROXY}" | cut -d: -f2)"
    JVM_OPTS="${JVM_OPTS}\n-Dhttps.proxyHost=$(echo "${JENKINS_PROXY}" | cut -d: -f1)"
    JVM_OPTS="${JVM_OPTS}\n-Dhttps.proxyPort=$(echo "${JENKINS_PROXY}" | cut -d: -f2)"
    warn "代理: ${JENKINS_PROXY}"
fi
# 压缩为单行
JVM_OPTS=$(echo "${JVM_OPTS}" | tr '\n' ' ' | sed 's/  */ /g')

cat > /etc/systemd/system/jenkins.service << SERVEOF
[Unit]
Description=Jenkins CI v${JENKINS_VERSION}
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${JENKINS_USER}
Group=${JENKINS_USER}
EnvironmentFile=/etc/sysconfig/jenkins
WorkingDirectory=${JENKINS_HOME}

ExecStart=/usr/bin/java ${JVM_OPTS} -jar \${JENKINS_WAR} --httpPort=\${HTTP_PORT} --httpListenAddress=0.0.0.0

ExecStop=/bin/kill -SIGTERM \$MAINPID
TimeoutStopSec=120
KillMode=mixed
Restart=on-failure
RestartSec=30

LimitNOFILE=65536
LimitNPROC=32768

# 安全加固
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=${JENKINS_HOME} ${JENKINS_LOG_DIR} ${JENKINS_RUN_DIR}
ReadOnlyPaths=${JENKINS_DIR}
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
PrivateDevices=yes

[Install]
WantedBy=multi-user.target
SERVEOF
chmod 644 /etc/systemd/system/jenkins.service

systemctl daemon-reload
systemctl enable jenkins 2>/dev/null || true
ok "systemd 服务已配置"

# ── 6. 防火墙 ──────────────────────────────────────────
step "[6/8] 防火墙..."
if ! ${SKIP_FW} && command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null 2>&1; then
    firewall-cmd --add-port="${JENKINS_PORT}"/tcp --permanent 2>/dev/null && ok "端口 ${JENKINS_PORT}/tcp"
    firewall-cmd --add-port="${AGENT_PORT}"/tcp --permanent 2>/dev/null && ok "Agent ${AGENT_PORT}/tcp"
    firewall-cmd --reload 2>/dev/null || true
else
    info "  跳过（--skip-firewall 或 firewalld 未启用）"
fi

# ── 7. 启动 ────────────────────────────────────────────
step "[7/8] 启动 Jenkins..."

pkill -f "jenkins.war" 2>/dev/null || true; sleep 1
systemctl start jenkins

for i in $(seq 1 30); do
    systemctl is-active jenkins &>/dev/null 2>&1 && { ok "systemd: active (${i}/30)"; break; }
    [ $i -eq 30 ] && { journalctl -u jenkins --no-pager -n 30 2>/dev/null || true; die "启动失败"; }
    sleep 2
done

# ── 8. HTTP 验证 ───────────────────────────────────────
step "[8/8] HTTP 验证..."

for i in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${JENKINS_PORT}/login" 2>/dev/null || echo "000")
    [ "${code}" = "200" ] || [ "${code}" = "403" ] && { ok "HTTP ${code} Jenkins 就绪 (${i}/20)"; break; }
    [ $i -eq 20 ] && warn "HTTP 未就绪 (${code})，Jenkins 可能仍在初始化"
    sleep 5
done

# ── 完成 ────────────────────────────────────────────────
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
echo ""; echo "============================================"
echo "  Jenkins ${JENKINS_VERSION} 安装完成"
echo ""
echo "  访问:       http://${HOST_IP}:${JENKINS_PORT}"
echo "  Agent:      ${AGENT_PORT}"
echo "  数据:       ${JENKINS_HOME}"
echo "  日志:       ${JENKINS_LOG_DIR}"
echo "  初始密码:   cat ${JENKINS_HOME}/secrets/initialAdminPassword"
echo ""
echo "  管理:       systemctl [start|stop|restart|status] jenkins"
echo "  卸载:       bash clean_jenkins.sh"
echo "============================================"
