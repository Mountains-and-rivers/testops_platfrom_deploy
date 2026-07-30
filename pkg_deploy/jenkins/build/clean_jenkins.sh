#!/bin/bash
# ============================================================
# Jenkins 精准清理脚本 — 与 build/install 完全对称
# 用法: bash clean_jenkins.sh [选项]
#   -a  全部（默认）   -j  仅 Jenkins 服务   -b  仅构建产物
#   -c  仅缓存         -u  仅用户           -m  仅 JDK/Maven
#   --yes 跳过确认    --backup 备份后清理
# ============================================================

# 强制使用 bash（sh/dash 不支持 pipefail）
[ -z "${BASH_VERSION:-}" ] && exec bash "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" "$@"

set -euo pipefail; cd /tmp

# ── 路径定义（与 build_jenkins.sh / install_jenkins.sh 保持一致）──
JENKINS_WAR="${JENKINS_WAR:-/opt/jenkins/jenkins.war}"
JENKINS_DIR="$(dirname "${JENKINS_WAR}")"                                # /opt/jenkins
JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_LOG_DIR="${JENKINS_LOG_DIR:-/var/log/jenkins}"
JENKINS_RUN_DIR="${JENKINS_RUN_DIR:-/run/jenkins}"
JENKINS_PORT="${JENKINS_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"
JENKINS_USER="${JENKINS_USER:-jenkins}"
BUILD_DIR="${BUILD_DIR:-/opt/build/jenkins}"                             # 源码+产物+Maven本地仓库
MAVEN_HOME="${MAVEN_HOME:-/opt/maven}"
CACHE_DIR="${CACHE_DIR:-/tmp/build-cache}"                               # 离线包缓存
# JDK 路径可能为 /opt/jdk11 /opt/jdk17 /opt/jdk21（取决于 Jenkins 版本）

# ── UI ──────────────────────────────────────────────────
readonly R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
info()  { echo -e "${G}[INFO]${N}  $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*"; }
step()  { echo -e "${C}[STEP]${N}  $*"; }
_ok()   { echo -e "  ${G}✓${N} $*"; }
_skip() { echo -e "  ${Y}−${N} $*"; }

# ── 安全校验 ────────────────────────────────────────────
_safe() {
    local p="$1"
    [ -z "${p}" ] && return 1
    for f in / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /var; do
        [ "${p}" = "${f}" ] && return 1
    done
    return 0
}

# ── 解析参数 ────────────────────────────────────────────
CA=false; CJ=false; CB=false; CC=false; CU=false; CM=false; CD=false; YES=false; BACKUP=false
while [[ $# -gt 0 ]]; do case "$1" in
    -a) CA=true ;; -j) CJ=true ;; -b) CB=true ;; -c) CC=true ;; -u) CU=true ;; -m) CM=true ;; -d) CD=true ;;
    -h) cat << 'USAGE'
用法: bash clean_jenkins.sh [选项]
  -a  全部（默认）   -j  Jenkins 服务   -b  构建产物
  -c  缓存           -u  用户          -m  JDK/Maven
  -d  Docker         --yes  跳过确认   --backup  备份
USAGE
exit 0 ;;
    --yes) YES=true ;; --backup) BACKUP=true ;;
    *) shift ;;
esac; shift 2>/dev/null || shift; done
${CA} || ${CJ} || ${CB} || ${CC} || ${CU} || ${CM} || ${CD} || CA=true

_confirm() {
    ${YES} && return 0
    echo ""; warn "  $1"; read -r -p "  确认? (yes/no): " a
    [ "${a}" = "yes" ] || { info "已取消"; exit 0; }
}

# ── 备份 ─────────────────────────────────────────────────
_backup() {
    ${BACKUP} || return 0
    local f="/tmp/jenkins_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    [ -d "${JENKINS_HOME}" ] && [ "$(ls -A "${JENKINS_HOME}" 2>/dev/null | wc -l)" -gt 0 ] && {
        tar -czf "${f}" -C "$(dirname "${JENKINS_HOME}")" "$(basename "${JENKINS_HOME}")" --exclude=workspace --exclude=cache 2>/dev/null
        _ok "备份: ${f} ($(du -h "${f}" | cut -f1))"
    }
}

# ── 清理函数 ────────────────────────────────────────────
_clean_service() {
    step "Jenkins 服务..."
    systemctl stop jenkins 2>/dev/null || true
    systemctl disable jenkins 2>/dev/null || true
    sleep 2
    pkill -SIGTERM -f "jenkins.war" 2>/dev/null || true; sleep 5
    pkill -SIGKILL -f "jenkins.war" 2>/dev/null || true

    rm -f /etc/systemd/system/jenkins.service /etc/systemd/system/multi-user.target.wants/jenkins.service
    systemctl daemon-reload 2>/dev/null || true; _ok "systemd"

    _safe "${JENKINS_DIR}" && rm -rf "${JENKINS_DIR}" && _ok "${JENKINS_DIR}"
    _safe "${JENKINS_HOME}" && rm -rf "${JENKINS_HOME}" && _ok "${JENKINS_HOME}"
    _safe "${JENKINS_LOG_DIR}" && rm -rf "${JENKINS_LOG_DIR}" && _ok "${JENKINS_LOG_DIR}" || true
    _safe "${JENKINS_RUN_DIR}" && rm -rf "${JENKINS_RUN_DIR}" && _ok "${JENKINS_RUN_DIR}" || true

    rm -f /etc/sysconfig/jenkins /etc/logrotate.d/jenkins /etc/profile.d/jenkins_java.sh /var/run/jenkins.pid
    rm -f /var/run/jenkins_build.lock 2>/dev/null || true
    _ok "配置文件"

    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --remove-port="${JENKINS_PORT}"/tcp --permanent 2>/dev/null && _ok "fw: ${JENKINS_PORT}"
        firewall-cmd --remove-port="${AGENT_PORT}"/tcp --permanent 2>/dev/null && _ok "fw: ${AGENT_PORT}"
        firewall-cmd --reload 2>/dev/null || true
    fi
}

_clean_build() {
    step "构建产物..."
    # ${BUILD_DIR} 包含: source/（源码）、.m2/（Maven本地仓库+Node缓存）、maven_build.log
    _safe "${BUILD_DIR}" && rm -rf "${BUILD_DIR}" && _ok "${BUILD_DIR} (源码+Maven仓库+Node缓存)" || _skip "${BUILD_DIR}"
    # 清理可能由 mvn 直接写入的用户级 .m2（尽管 build 脚本使用 -Dmaven.repo.local）
    for d in ~/.m2 /root/.m2 "${JENKINS_HOME}/.m2"; do [ -d "${d}" ] && rm -rf "${d}" && _ok "${d}"; done
    _safe "${MAVEN_HOME}" && [ -d "${MAVEN_HOME}" ] && rm -rf "${MAVEN_HOME}" && _ok "${MAVEN_HOME}"
}

_clean_cache() {
    step "缓存..."
    # 与 build_jenkins.sh _download() 的 CACHE_DIR 对应
    _safe "${CACHE_DIR}" && rm -rf "${CACHE_DIR}" && _ok "${CACHE_DIR}" || _skip "${CACHE_DIR}"
    # /tmp 下的零散下载包
    rm -f /tmp/jdk*.tar.gz /tmp/apache-maven-*.tar.gz /tmp/jenkins-*.zip /tmp/node-v*.tar.gz /tmp/yarn-v*.tar.gz 2>/dev/null || true
    rm -rf /tmp/jdk*_extract /tmp/maven_extract /tmp/jenkins_extract /tmp/maven-build 2>/dev/null || true
    # Maven 本地仓库中的 Node 缓存（若 BUILD_DIR 未被清理时仍有残留）
    if [ -d "${BUILD_DIR}/.m2/com/github/eirslett/node" ]; then
        rm -rf "${BUILD_DIR}/.m2/com/github/eirslett/node" && _ok "Node Maven 缓存"
    fi
    # Maven 本地仓库中的 JDK 缓存（download 方式安装的可能残留）
    for _jdk_cache in "${BUILD_DIR}/.m2/org/adoptium" "${BUILD_DIR}/.m2/net/java/openjdk"; do
        [ -d "${_jdk_cache}" ] && rm -rf "${_jdk_cache}" && _ok "$(basename "${_jdk_cache}") Maven 缓存"
    done
}

_clean_user() {
    step "用户..."
    pkill -SIGKILL -u "${JENKINS_USER}" 2>/dev/null || true
    userdel -r "${JENKINS_USER}" 2>/dev/null && _ok "用户 ${JENKINS_USER}" || _skip "用户 ${JENKINS_USER}"
    groupdel "${JENKINS_USER}" 2>/dev/null && _ok "组 ${JENKINS_USER}" || true
    if [ -d "/home/${JENKINS_USER}" ] && ! ls /home/${JENKINS_USER}/*.sh >/dev/null 2>&1; then
        rm -rf "/home/${JENKINS_USER}" && _ok "/home/${JENKINS_USER}"
    else
        _skip "/home/${JENKINS_USER} (含脚本，保留)"
    fi
}

_clean_jdk_maven() {
    step "JDK/Maven..."
    _safe "${MAVEN_HOME}" && [ -d "${MAVEN_HOME}" ] && rm -rf "${MAVEN_HOME}" && _ok "${MAVEN_HOME}"
    # build_jenkins.sh 根据 Jenkins 版本自动选择: jdk11 / jdk17 / jdk21
    for d in /opt/jdk* /opt/java* /opt/openjdk*; do
        [ -d "${d}" ] && _safe "${d}" && rm -rf "${d}" && _ok "${d}"
    done
    rm -f /etc/profile.d/jenkins_java.sh 2>/dev/null || true
    # Maven 用户级本地仓库（构建脚本使用 -Dmaven.repo.local，此处清理作为兜底）
    for d in ~/.m2 /root/.m2; do [ -d "${d}" ] && rm -rf "${d}" && _ok "${d}"; done
}

_clean_docker() {
    step "Docker 容器/数据卷..."
    if command -v docker &>/dev/null; then
        # 停止并删除容器
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^jenkins$'; then
            docker stop jenkins 2>/dev/null && _ok "容器已停止"
            docker rm jenkins 2>/dev/null && _ok "容器已删除"
        else
            _skip "容器 jenkins"
        fi
        # 删除镜像
        if docker images '*/jenkins:*' --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q jenkins; then
            docker rmi -f $(docker images '*/jenkins:*' -q) 2>/dev/null && _ok "镜像已删除" || true
        else
            _skip "镜像 jenkins"
        fi
        # 删除数据卷
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q '^jenkins_home$'; then
            docker volume rm jenkins_home 2>/dev/null && _ok "数据卷 jenkins_home" || _skip "数据卷 jenkins_home (仍挂载?)"
        else
            _skip "数据卷 jenkins_home"
        fi
        # 清理构建缓存
        docker builder prune -f 2>/dev/null && _ok "Docker 构建缓存" || true
    else
        _skip "Docker 未安装"
    fi
}

# ══════════════════════════════════════════════════════════
echo "============================================"
echo "  Jenkins 精准清理"
echo "============================================"
echo ""
${CA} && echo "  全部（服务+数据+Docker+构建+缓存+用户+JDK/Maven）"
${CJ} && echo "  Jenkins 服务（systemd、WAR、${JENKINS_HOME}）"
${CB} && echo "  构建产物（${BUILD_DIR}）"
${CC} && echo "  缓存（/tmp/build-cache）"
${CU} && echo "  用户 ${JENKINS_USER}"
${CM} && echo "  JDK/Maven"
${CD} && echo "  Docker（容器+镜像+数据卷）"

${CA} && _confirm "删除 Jenkins 全部文件和数据（不可恢复）！"
${CJ} && ! ${CA} && _confirm "删除 Jenkins 服务及数据: ${JENKINS_HOME}"

_backup
${CA} && { _clean_service; _clean_docker; _clean_build; _clean_cache; _clean_user; _clean_jdk_maven; }
${CJ} && _clean_service
${CB} && _clean_build
${CC} && _clean_cache
${CU} && _clean_user
${CM} && _clean_jdk_maven
${CD} && _clean_docker

echo ""; echo "============================================"
echo "  清理完成"
echo "  重装: bash build_jenkins.sh && bash install_jenkins.sh"
echo "============================================"
