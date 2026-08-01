#!/bin/bash
# ============================================================
# MeterSphere v3.x — 源码编译构建（CentOS 9）
#
# 原理:      git clone / 本地源码 tarball → Maven 编译 → JAR
# 本地优先:  脚本同目录 metersphere*.tar.gz + OpenJDK*.tar.gz + apache-maven*.tar.gz
#
# 用法:      bash build_metersphere.sh [版本分支] [--skip-jdk] [--skip-maven]
# 示例:      bash build_metersphere.sh v3.6.0
# ============================================================
set -euo pipefail

# 必须在 cd 之前计算脚本目录，否则相对路径 $0 会解析到 /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo '/tmp')"
cd /tmp

# ── 配置 ──
MS_VERSION="${1:-v3.6.0}"
SKIP_JDK=false; SKIP_MAVEN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-jdk)   SKIP_JDK=true; shift ;;
        --skip-maven) SKIP_MAVEN=true; shift ;;
        *) MS_VERSION="$1"; shift ;;
    esac
done

JDK_VERSION="17.0.13"
JDK_TAR="OpenJDK17U-jdk_x64_linux_hotspot_${JDK_VERSION}_11.tar.gz"
JDK_URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-${JDK_VERSION}%2B11/${JDK_TAR}"
MAVEN_VERSION="3.9.16"
MAVEN_TAR="apache-maven-${MAVEN_VERSION}-bin.tar.gz"
MAVEN_URL="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/${MAVEN_TAR}"
MS_REPO="https://github.com/metersphere/metersphere.git"
MS_DIR="/opt/metersphere"
JDK_DIR="/opt/jdk17"
MAVEN_DIR="/opt/maven"

# ── UI ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
err()   { echo -e "\n${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${RED}  ✗ ${BASH_SOURCE[0]}:${BASH_LINENO[0]}${NC}"; echo -e "${RED}  $*${NC}"; echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; exit 1; }
trap 'err "脚本异常退出 (exit code=$?)"' ERR

get_local() {
    for d in "${SCRIPT_DIR}/" "/tmp/build-cache/" "./" "${HOME}/"; do
        [ -f "${d}$1" ] && [ -s "${d}$1" ] && { echo "${d}$1"; return 0; }
    done
    return 1
}

echo "============================================"
echo "  MeterSphere 源码构建（CentOS 9）"
echo "  版本: ${MS_VERSION}"
echo "  JDK:  ${JDK_VERSION}  |  Maven: ${MAVEN_VERSION}"
echo "  安装: ${MS_DIR}"
echo "============================================"

# ═══ 1. JDK ═══
step "[1/5] JDK ${JDK_VERSION}..."

if ${SKIP_JDK}; then
    info "  --skip-jdk，跳过"
elif [ -x "${JDK_DIR}/bin/java" ] && ${JDK_DIR}/bin/java --version 2>&1 | grep -q "${JDK_VERSION}"; then
    info "  ✓ JDK $( ${JDK_DIR}/bin/java --version 2>&1 | head -1)"
else
    if _JDK_PKG=$(get_local "${JDK_TAR}"); then
        info "  使用本地: $(basename ${_JDK_PKG}) ($(du -h ${_JDK_PKG} | cut -f1))"
        cp "${_JDK_PKG}" "/tmp/${JDK_TAR}"
    else
        info "  下载: ${JDK_URL}"
        wget -q --show-progress -O "/tmp/${JDK_TAR}" "${JDK_URL}" 2>/dev/null \
            || curl -L -o "/tmp/${JDK_TAR}" "${JDK_URL}" \
            || err "JDK 下载失败"
        mkdir -p /tmp/build-cache && cp "/tmp/${JDK_TAR}" "/tmp/build-cache/${JDK_TAR}" 2>/dev/null || true
    fi
    rm -rf "${JDK_DIR}"
    mkdir -p "${JDK_DIR}"
    tar -xzf "/tmp/${JDK_TAR}" -C "${JDK_DIR}" --strip-components=1
    for _bin in "${JDK_DIR}"/bin/*; do
        ln -sf "${_bin}" "/usr/local/bin/$(basename ${_bin})" 2>/dev/null || true
    done
    rm -f "/tmp/${JDK_TAR}"
    info "  ✓ $(java --version 2>&1 | head -1)"
fi

# ═══ 2. Maven ═══
step "[2/5] Maven ${MAVEN_VERSION}..."

if ${SKIP_MAVEN}; then
    info "  --skip-maven，跳过"
elif [ -x "${MAVEN_DIR}/bin/mvn" ] && ${MAVEN_DIR}/bin/mvn --version 2>&1 | grep -q "${MAVEN_VERSION}"; then
    info "  ✓ $( ${MAVEN_DIR}/bin/mvn --version 2>&1 | head -1)"
else
    if _MVN_PKG=$(get_local "${MAVEN_TAR}"); then
        info "  使用本地: $(basename ${_MVN_PKG}) ($(du -h ${_MVN_PKG} | cut -f1))"
        cp "${_MVN_PKG}" "/tmp/${MAVEN_TAR}"
    else
        info "  下载: ${MAVEN_URL}"
        wget -q --show-progress -O "/tmp/${MAVEN_TAR}" "${MAVEN_URL}" 2>/dev/null \
            || curl -L -o "/tmp/${MAVEN_TAR}" "${MAVEN_URL}" \
            || err "Maven 下载失败"
        mkdir -p /tmp/build-cache && cp "/tmp/${MAVEN_TAR}" "/tmp/build-cache/${MAVEN_TAR}" 2>/dev/null || true
    fi
    rm -rf "${MAVEN_DIR}"
    mkdir -p "${MAVEN_DIR}"
    tar -xzf "/tmp/${MAVEN_TAR}" -C "${MAVEN_DIR}" --strip-components=1
    ln -sf "${MAVEN_DIR}/bin/mvn" /usr/local/bin/mvn 2>/dev/null || true
    rm -f "/tmp/${MAVEN_TAR}"
    info "  ✓ $(mvn --version 2>&1 | head -1)"
fi

export JAVA_HOME="${JDK_DIR}"
export MAVEN_HOME="${MAVEN_DIR}"
export PATH="${JAVA_HOME}/bin:${MAVEN_HOME}/bin:${PATH}"

# ═══ 3. 获取源码 ═══
step "[3/5] 获取 MeterSphere 源码..."

if [ -d "${MS_DIR}/.git" ]; then
    info "  已存在 git 仓库，更新..."
    cd "${MS_DIR}"
    git pull --ff-only 2>/dev/null || warn "  git pull 失败，继续使用现有代码"
else
    rm -rf "${MS_DIR}"
    _SRC_TAR=$(ls "${SCRIPT_DIR}/"metersphere*.tar.gz 2>/dev/null | head -1) || true
    if [ -n "${_SRC_TAR}" ] && [ -s "${_SRC_TAR}" ]; then
        info "  使用本地: $(basename ${_SRC_TAR}) ($(du -h ${_SRC_TAR} | cut -f1))"
        mkdir -p "${MS_DIR}"
        tar -xzf "${_SRC_TAR}" -C "${MS_DIR}" --strip-components=1
    else
        info "  git clone ${MS_REPO} (${MS_VERSION})..."
        git clone --depth 1 --branch "${MS_VERSION}" "${MS_REPO}" "${MS_DIR}" 2>&1 \
            || git clone --depth 1 "${MS_REPO}" "${MS_DIR}" 2>&1 \
            || err "git clone 失败，请手动下载源码包放到 ${SCRIPT_DIR}/"
    fi
fi

[ -f "${MS_DIR}/pom.xml" ] || err "源码不完整: ${MS_DIR}/pom.xml 不存在"
info "  ✓ 源码就绪: ${MS_DIR}"

# ═══ 4. Maven 编译 ═══
step "[4/5] Maven 编译（10-30 分钟）..."

cd "${MS_DIR}"

# 国内 Maven 镜像加速
mkdir -p ~/.m2
cat > ~/.m2/settings.xml << MVNSET
<settings>
  <mirrors>
    <mirror>
      <id>aliyun</id>
      <mirrorOf>central</mirrorOf>
      <name>Aliyun Maven Mirror</name>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
</settings>
MVNSET

mvn clean package -DskipTests -Dmaven.test.skip=true -Pprod 2>&1 | tail -10 \
    || mvn clean package -DskipTests -Dmaven.test.skip=true 2>&1 | tail -10 \
    || err "Maven 编译失败"

# 找到生成的 JAR
MS_JAR=$(find "${MS_DIR}" -name "metersphere*.jar" -not -name "*sources*" -not -name "*javadoc*" | head -1)
[ -n "${MS_JAR}" ] && [ -f "${MS_JAR}" ] || err "未找到编译产物 JAR"
info "  ✓ 编译产物: ${MS_JAR}"

# ═══ 5. 完成 ═══
step "[5/5] 构建完成"

echo ""
echo "============================================"
echo "  MeterSphere ${MS_VERSION} 构建完成"
echo ""
echo "  源码:     ${MS_DIR}"
echo "  产物:     ${MS_JAR}"
echo "  下一步:   bash install_metersphere.sh [--port 8081]"
echo "============================================"
