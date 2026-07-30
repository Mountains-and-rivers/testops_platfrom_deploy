#!/bin/bash
# ============================================================
# Jenkins 源码编译脚本 — 产出 jenkins.war（纯构建，不部署）
#
# 用法:
#   bash build_jenkins.sh                    # 默认版本 2.479.1
#   bash build_jenkins.sh 2.479.2            # 指定版本
#
# 产出:
#   /opt/jenkins/jenkins.war                 # 编译产物
#   /opt/jenkins/jenkins.war.sha256          # 校验和
#
# 后续步骤:
#   bash install_jenkins.sh                  # 裸机 systemd 部署
#   bash build_image.sh --prebuilt           # Docker 镜像构建
# ============================================================
set -euo pipefail

# ── 脚本目录 ─────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$(pwd)")"

# ── 可覆盖参数 ──────────────────────────────────────────
JENKINS_VERSION="${JENKINS_VERSION:-2.479.1}"
JENKINS_WAR="${JENKINS_WAR:-/opt/jenkins/jenkins.war}"
JENKINS_DIR="$(dirname "${JENKINS_WAR}")"
BUILD_DIR="${BUILD_DIR:-/opt/build/jenkins}"
SRC_DIR="${BUILD_DIR}/source"
MAVEN_HOME="${MAVEN_HOME:-/opt/maven}"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.16}"
MAVEN_HEAP="${MAVEN_HEAP:-2048m}"
CACHE_DIR="${CACHE_DIR:-/tmp/build-cache}"
GITHUB_REPO="${GITHUB_REPO:-https://github.com/jenkinsci/jenkins.git}"

# JDK 版本自动匹配 (Jenkins 2.463+ → JDK17, 2.361+ → JDK11)
_detect_jdk() {
    local m; m=$(echo "${JENKINS_VERSION}" | cut -d. -f1)
    local n; n=$(echo "${JENKINS_VERSION}" | cut -d. -f2)
    # 参考 Jenkins 官方 Java 支持策略: https://www.jenkins.io/doc/book/platform-information/support-policy-java/
    if [ "${m}" -ge 3 ] || { [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 555 ]; }; then echo "21"   # 2.555+ → JDK 21
    elif [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 463 ]; then echo "17"                          # 2.463+ → JDK 17
    elif [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 361 ]; then echo "11"                          # 2.361+ → JDK 11
    else echo "11"; fi
}
JDK_VERSION="${JDK_VERSION:-$(_detect_jdk)}"

# 从源码 pom.xml 读实际 Jenkins 版本并推断 JDK（比命令行参数更准确）
_detect_jdk_from_pom() {
    local pom="${SRC_DIR}/pom.xml"
    [ -f "${pom}" ] || { return 1; }
    # 读 <version>X.Y.Z</version>（也可能是 X.Y.Z-SNAPSHOT）
    local v; v=$(sed -n 's/.*<version>\([0-9.]*\).*<\/version>.*/\1/p' "${pom}" | head -1)
    [ -z "${v}" ] && return 1
    # 跳过非数字开头的版本（如 parent POM 的版本引用）
    echo "${v}" | grep -qE '^[0-9]' || return 1
    local m; m=$(echo "${v}" | cut -d. -f1)
    local n; n=$(echo "${v}" | cut -d. -f2)
    # 相同的 JDK 匹配逻辑
    if [ "${m}" -ge 3 ] || { [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 555 ]; }; then echo "21"
    elif [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 463 ]; then echo "17"
    elif [ "${m}" -eq 2 ] && [ "${n:-0}" -ge 361 ]; then echo "11"
    else echo "11"; fi
    return 0
}
JAVA_HOME_TARGET="${JAVA_HOME_TARGET:-/opt/jdk${JDK_VERSION}}"

# ── UI ──────────────────────────────────────────────────
readonly R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
info()  { echo -e "${G}[INFO]${N}  $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*"; }
step()  { echo -e "${C}[STEP]${N}  $*"; }
ok()    { echo -e "  ${G}[OK]${N} $*"; }
die()   { echo -e "\n${R}━━━━ 错误: ${BASH_SOURCE[0]}:${BASH_LINENO[0]} ━━━━${N}\n${R}  $*${N}\n"; exit 1; }
trap 'die "脚本异常退出 (exit=$?)"' ERR

mkdir -p "${CACHE_DIR}"

# ── 工具函数 ───────────────────────────────────────────
# $1=url $2=保存文件名 [$3=可选的本地匹配通配符，如 "OpenJDK17U*.tar.gz"]
_download() {
    local url="$1" fname="$2" alt="${3:-}" d
    # 精确匹配优先
    for d in "${SCRIPT_DIR}/" "${CACHE_DIR}/" "./"; do
        [ -f "${d}${fname}" ] && [ -s "${d}${fname}" ] && { [ "${d}${fname}" != "./${fname}" ] && cp "${d}${fname}" "./${fname}"; info "  本地: ${d}${fname}"; return 0; }
    done
    # 模糊匹配（适配用户下载的原始文件名）
    if [ -n "${alt}" ]; then
        for d in "${SCRIPT_DIR}/" "${CACHE_DIR}/"; do
            local found; found=$(ls -t "${d}"${alt} 2>/dev/null | head -1)
            if [ -n "${found}" ] && [ -s "${found}" ]; then
                cp "${found}" "./${fname}" && info "  本地: ${found}" && return 0
            fi
        done
    fi
    info "  下载: ${url}"
    wget -q --show-progress --timeout=120 --tries=3 -O "${fname}" "${url}" || die "下载失败: ${url}"
    cp "${fname}" "${CACHE_DIR}/${fname}" 2>/dev/null || true
}

# ── 预检 ───────────────────────────────────────────────
_precheck() {
    info "环境预检..."
    local bad=0

    # OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${PRETTY_NAME}" | grep -qiE "CentOS|Rocky|AlmaLinux|RHEL|Red Hat" && ok "OS: ${PRETTY_NAME}" || { warn "OS: ${PRETTY_NAME}"; bad=1; }
    else warn "OS: 未知"; bad=1; fi

    # 架构
    local a; a=$(uname -m)
    [[ "${a}" =~ ^(x86_64|aarch64)$ ]] && ok "架构: ${a}" || { warn "架构: ${a}"; bad=1; }

    # 内存
    local m; m=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    [ "${m}" -ge 4 ] 2>/dev/null && ok "内存: ${m}GB" || { warn "内存: ${m}GB (建议≥4GB)"; }

    # 磁盘
    mkdir -p "${BUILD_DIR}" 2>/dev/null || true
    local d; d=$(timeout 5 df -BG "${BUILD_DIR}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G' || echo 0)
    [ -z "${d}" ] && d=0
    [ "${d}" -ge 20 ] 2>/dev/null && ok "磁盘: ${d}GB" || { warn "磁盘: ${d}GB (建议≥20GB)"; }

    # 必需工具
    for tool in git wget unzip; do
        command -v "${tool}" &>/dev/null && ok "${tool}" || { warn "安装 ${tool}..."; dnf install -y "${tool}" 2>/dev/null || yum install -y "${tool}" 2>/dev/null || die "${tool} 安装失败"; ok "${tool}"; }
    done

    # expect (git clone 免交互)
    command -v expect &>/dev/null || { dnf install -y expect 2>/dev/null || yum install -y expect 2>/dev/null || true; }

    [ "${bad}" -eq 1 ] && die "关键环境检查未通过"
    ok "预检通过"
}

# ── JDK ──────────────────────────────────────────────────
_ensure_jdk() {
    step "JDK ${JDK_VERSION}..."

    # 按优先级搜索已有 JDK
    local candidates=(
        "${JAVA_HOME_TARGET}/bin/java"
        "/usr/lib/jvm/java-${JDK_VERSION}-openjdk/bin/java"
    )
    # 也搜索通配路径
    for c in /usr/lib/jvm/java-${JDK_VERSION}*/bin/java /usr/lib/jvm/jre-${JDK_VERSION}*/bin/java; do
        [ -x "${c}" ] && candidates+=("${c}")
    done

    for c in "${candidates[@]}"; do
        [ -x "${c}" ] || continue
        JAVA_HOME="$(dirname "$(dirname "${c}")")"
        export JAVA_HOME PATH="${JAVA_HOME}/bin:${PATH}"
        ok "JDK: $("${c}" -version 2>&1 | head -1)"
        ln -sf "${JAVA_HOME}" "${JAVA_HOME_TARGET}" 2>/dev/null || true
        return 0
    done

    # dnf 安装
    warn "尝试 dnf 安装 java-${JDK_VERSION}-openjdk-devel..."
    if dnf install -y "java-${JDK_VERSION}-openjdk-devel" 2>/dev/null; then
        JAVA_HOME="/usr/lib/jvm/java-${JDK_VERSION}-openjdk"
        export JAVA_HOME PATH="${JAVA_HOME}/bin:${PATH}"
        ln -sf "${JAVA_HOME}" "${JAVA_HOME_TARGET}" 2>/dev/null || true
        ok "JDK: $(java -version 2>&1 | head -1)"
        return 0
    fi

    # 手动下载 Adoptium
    warn "手动安装 Eclipse Temurin JDK ${JDK_VERSION}..."
    local arch; arch=$(uname -m); [ "${arch}" = "aarch64" ] && arch="aarch64" || arch="x64"
    local jdk_url
    case "${JDK_VERSION}" in
        21) jdk_url="https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.9%2B10/OpenJDK21U-jdk_${arch}_linux_hotspot_21.0.9_10.tar.gz" ;;
        17) jdk_url="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_${arch}_linux_hotspot_17.0.19_10.tar.gz" ;;
        11) jdk_url="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.29%2B10/OpenJDK11U-jdk_${arch}_linux_hotspot_11.0.29_10.tar.gz" ;;
        *)  die "不支持的 JDK: ${JDK_VERSION}" ;;
    esac
    local pkg="jdk${JDK_VERSION}.tar.gz"
    cd /tmp; _download "${jdk_url}" "${pkg}" "OpenJDK${JDK_VERSION}U*.tar.gz"
    mkdir -p "${JAVA_HOME_TARGET}"
    tar -xzf "${pkg}" -C "${JAVA_HOME_TARGET}" --strip-components=1
    rm -f "${pkg}"
    JAVA_HOME="${JAVA_HOME_TARGET}"; export JAVA_HOME PATH="${JAVA_HOME}/bin:${PATH}"
    ok "JDK: $(java -version 2>&1 | head -1)"
}

# ── Maven ────────────────────────────────────────────────
_ensure_maven() {
    step "Maven ${MAVEN_VERSION}..."

    if [ -x "${MAVEN_HOME}/bin/mvn" ]; then
        export PATH="${MAVEN_HOME}/bin:${PATH}"; ok "Maven: $(mvn --version 2>&1 | head -1)"; return 0
    fi
    if command -v mvn &>/dev/null; then
        ok "Maven(系统): $(mvn --version 2>&1 | head -1)"; return 0
    fi

    local pkg="apache-maven-${MAVEN_VERSION}-bin.tar.gz"
    local url="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/${pkg}"
    cd /tmp; _download "${url}" "${pkg}" "apache-maven-*.tar.gz"
    mkdir -p "${MAVEN_HOME}"
    tar -xzf "${pkg}" -C "${MAVEN_HOME}" --strip-components=1
    rm -f "${pkg}"
    export PATH="${MAVEN_HOME}/bin:${PATH}"
    ok "Maven: $(mvn --version 2>&1 | head -1)"
}

# ── Maven settings.xml (国内镜像加速) ──────────────────
_gen_maven_settings() {
    mkdir -p ~/.m2
    cat > ~/.m2/settings.xml << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings>
  <mirrors>
    <mirror>
      <id>aliyun-maven</id>
      <mirrorOf>central</mirrorOf>
      <name>Aliyun Maven</name>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
  <profiles>
    <profile>
      <id>aliyun</id>
      <repositories>
        <repository><id>central</id><url>https://maven.aliyun.com/repository/public</url><releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository><id>central</id><url>https://maven.aliyun.com/repository/public</url><releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots></pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles><activeProfile>aliyun</activeProfile></activeProfiles>
</settings>
XMLEOF
    info "  Maven 镜像: aliyun"
}

# ── 获取源码 ─────────────────────────────────────────────
_fetch_source() {
    step "获取 Jenkins v${JENKINS_VERSION} 源码..."
    mkdir -p "${BUILD_DIR}" && cd "${BUILD_DIR}"

    local zip_name="jenkins-${JENKINS_VERSION}.zip"
    # 精确匹配优先，也接受 jenkins.zip（本地包通用名）
    local _zip_src=""
    for z in "${zip_name}" "jenkins.zip"; do
        for d in "${SCRIPT_DIR}/" "${CACHE_DIR}/"; do
            [ -f "${d}${z}" ] && [ -s "${d}${z}" ] && { _zip_src="${d}${z}"; break 2; }
        done
    done
    if [ -n "${_zip_src}" ]; then
        info "  本地: ${_zip_src}"; rm -rf "${SRC_DIR}" 2>/dev/null || true
        # unzip 遇到 Unicode 文件名会警告但解压成功（退出码可能是 1），加 || true 防止 set -e 中断
        unzip -o "${_zip_src}" -d "${SRC_DIR}" 2>&1 | grep -v 'mismatching\|continuing with' || true
        # GitHub zip 包有个外层目录（如 jenkins-jenkins-2.479.1/），自动剥掉
        local _top; _top=$(ls -1 "${SRC_DIR}" 2>/dev/null | head -1)
        if [ -n "${_top}" ] && [ -d "${SRC_DIR}/${_top}" ] && [ "$(ls -A "${SRC_DIR}" | wc -l)" -eq 1 ]; then
            mv "${SRC_DIR}/${_top}"/* "${SRC_DIR}/" 2>/dev/null || true
            mv "${SRC_DIR}/${_top}"/.[!.]* "${SRC_DIR}/" 2>/dev/null || true
            rmdir "${SRC_DIR}/${_top}" 2>/dev/null || true
        fi
        [ -f "${SRC_DIR}/pom.xml" ] || die "解压后未找到 ${SRC_DIR}/pom.xml，请检查 zip 包结构"
    elif [ -f "${SRC_DIR}/pom.xml" ]; then
        info "  已有源码: ${SRC_DIR}"
    elif [ -f "${SRC_DIR}/pom.xml" ]; then
        ok "已有源码: ${SRC_DIR}"; return 0
    else
        local tag="jenkins-${JENKINS_VERSION}"
        info "  git clone --depth 1 --branch ${tag}..."
        rm -rf "${SRC_DIR}" 2>/dev/null || true
        for i in 1 2 3; do
            info "  尝试 ${i}/3..."
            expect -c "
log_user 1; set timeout 300
spawn git clone --depth 1 --branch ${tag} ${GITHUB_REPO} ${SRC_DIR}
expect { \"*yes/no*\" { send \"yes\r\"; exp_continue } \"*fingerprint*\" { send \"yes\r\"; exp_continue } \"*Username*\" { send \"\r\"; exp_continue } \"*Password*\" { send \"\r\"; exp_continue } timeout { exit 1 } eof {} }
catch wait result; exit [lindex \$result 3]" 2>&1
            [ -f "${SRC_DIR}/pom.xml" ] && break
            rm -rf "${SRC_DIR}" 2>/dev/null || true; sleep 10
        done
    fi
    [ -f "${SRC_DIR}/pom.xml" ] || die "源码获取失败，${SRC_DIR}/pom.xml 不存在"
    rm -rf "${SRC_DIR}/.git" "${SRC_DIR}/.github" 2>/dev/null || true

    # 移除 test 模块（集成测试，需要 maven-hpi-plugin 等 Jenkins 私有插件，编译 WAR 不需要）
    if [ -d "${SRC_DIR}/test" ]; then
        rm -rf "${SRC_DIR}/test"
        sed -i 's/<module>test<\/module>//g' "${SRC_DIR}/pom.xml"
        info "  已移除 test 模块（避免 maven-hpi-plugin 解析失败）"
    fi

    # 修复 Windows CRLF（zip 打包可能带入）
    find "${SRC_DIR}" -type f ! -name '*.jar' ! -name '*.gz' ! -name '*.zip' -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
    ok "源码就绪: ${SRC_DIR}"
}

# ── Maven 编译 ──────────────────────────────────────────
# 参考 Jenkins 官方 CONTRIBUTING.md:
#   https://github.com/jenkinsci/jenkins/blob/master/CONTRIBUTING.md#building-the-war-file
# 企业级最佳实践: -Pquick-build + clean install
# Node.js: 必须提前放入 Maven 缓存（-Dskip.npm 对 install-node-and-corepack goal 无效）
_compile() {
    step "Maven 编译 (约 10-30 分钟)..."
    cd "${SRC_DIR}"

    _gen_maven_settings
    export MAVEN_OPTS="-Xmx${MAVEN_HEAP} -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/tmp"
    local repo="${BUILD_DIR}/.m2"; mkdir -p "${repo}"
    local log="${BUILD_DIR}/maven_build.log"

    # ── Node.js / frontend-maven-plugin ─────────────────
    # frontend-maven-plugin 从 Maven 本地仓库缓存读取 node tarball:
    #   {repo}/com/github/eirslett/node/{version}/node-{version}-linux-x64.tar.gz
    # 把本地 node 包预填充到该路径，插件就会跳过下载，直接解压安装
    # 有 node 包 → 预填充缓存，保留 yarn install/build，只 skip lint
    # 无 node 包 → 全部 skip，用预编译前端资源
    local node_tarball="" node_fname="" node_ver="" _d _f
    shopt -s nullglob
    for _d in "${SCRIPT_DIR}" "${SCRIPT_DIR}/.." "${CACHE_DIR}" "${PWD}" "${PWD}/build"; do
        [ -d "${_d}" ] || continue
        for _f in "${_d}/"node-v*-linux-x64.tar.gz; do
            [ -f "${_f}" ] && [ -s "${_f}" ] || continue
            node_tarball="${_f}"; break 2
        done
    done
    shopt -u nullglob

    local _pom="${SRC_DIR}/pom.xml"

    # 从 pom.xml 读取 frontend-maven-plugin 要求的 <nodeVersion>
    # 支持两种写法:
    #   1) 字面量: <nodeVersion>v24.18.0</nodeVersion>
    #   2) 属性引用: <nodeVersion>${node.version}</nodeVersion>（需查找属性定义）
    _pom_node_ver() {
        local v
        # 1) 在整个源码树搜索 <nodeVersion> 字面量
        v=$(find "${SRC_DIR}" -maxdepth 3 -name "pom.xml" -exec sed -n 's/.*<nodeVersion>v\{0,1\}\([0-9.]*\)<\/nodeVersion>.*/\1/p' {} \; 2>/dev/null | head -1)
        [ -n "${v}" ] && echo "${v}" && return 0
        # 2) 查找属性定义 <node.version> 或 <git-state.node.version>
        for _prop in "node\.version" "git-state\.node\.version"; do
            v=$(find "${SRC_DIR}" -maxdepth 3 -name "pom.xml" -exec sed -n "s/.*<${_prop}>v\{0,1\}\([0-9.]*\)<\/${_prop}>.*/\1/p" {} \; 2>/dev/null | head -1)
            [ -n "${v}" ] && echo "${v}" && return 0
        done
        return 1
    }

    if [ -n "${node_tarball}" ] && [ -f "${_pom}" ] && grep -q 'frontend-maven-plugin' "${_pom}" 2>/dev/null; then
        node_fname=$(basename "${node_tarball}")
        node_ver=$(echo "${node_fname}" | sed 's/node-v\([0-9.]*\)-.*/\1/')
        local pom_node_ver; pom_node_ver=$(_pom_node_ver || echo "")

        # 版本匹配（或无法解析 pom 版本时仍尝试预填充）→ 预填充缓存
        if [ -z "${pom_node_ver}" ] || [ "${pom_node_ver}" = "${node_ver}" ]; then
            local node_cache_dir="${repo}/com/github/eirslett/node/${node_ver}"
            mkdir -p "${node_cache_dir}"
            # 缓存文件名: node-{ver}-linux-x64.tar.gz（不带 v 前缀，与插件内部命名一致）
            cp "${node_tarball}" "${node_cache_dir}/node-${node_ver}-linux-x64.tar.gz"
            if [ -z "${pom_node_ver}" ]; then
                warn "  Node: 未能解析 pom nodeVersion，使用本地 v${node_ver} 预填充缓存"
            else
                info "  Node: v${node_ver} → Maven 本地缓存，保留 yarn install/build（只 skip lint）"
            fi

            # skip lint 类 execution（yarn lint:ci / prettier / yarn lint）
            for _id in "yarn lint:ci" "prettier" "yarn lint"; do
                sed -i '/<id>'"${_id}"'<\/id>/,/<\/execution>/{
                    /<configuration>/a\              <skip>true</skip>
                }' "${_pom}"
            done
        else
            # 版本明确不匹配 → 全部 skip
            sed -i '/<artifactId>frontend-maven-plugin<\/artifactId>/,/<\/plugin>/{
                /<configuration>/a\              <skip>true</skip>
            }' "${_pom}"
            warn "  Node: 本地 v${node_ver} != pom 要求 v${pom_node_ver}，跳过全部 frontend goal（使用预编译前端资源）"
        fi
    elif [ -f "${_pom}" ] && grep -q 'frontend-maven-plugin' "${_pom}" 2>/dev/null; then
        # 无 node → 全部 skip，用预编译前端资源
        sed -i '/<artifactId>frontend-maven-plugin<\/artifactId>/,/<\/plugin>/{
            /<configuration>/a\              <skip>true</skip>
        }' "${_pom}"
        warn "  Node: 未找到本地包，跳过全部 frontend goal（使用预编译前端资源）"
    fi

    # -Pquick-build   官方快速构建 profile，自动跳过 tests/spotbugs/checkstyle
    local mvn_opts=(
        -pl war,bom -am
        -Pquick-build
        -Dmaven.buildNumber.skip=true
        -Dmaven.repo.local="${repo}"
        -Djenkins.version="${JENKINS_VERSION}"
        --batch-mode --no-transfer-progress
    )

    info "  日志: ${log}"
    info "  官方: mvn -am -pl war,bom -Pquick-build clean install"

    # 最多重试 2 次（首次 clean install 拉取依赖，重试 -o 离线用缓存增量续跑）
    local retry=0 war_file="" mvn_goal="clean install" mvn_offline=""
    while [ ${retry} -lt 2 ]; do
        if mvn "${mvn_opts[@]}" ${mvn_goal} ${mvn_offline} 2>&1 | tee "${log}"; then
            break
        fi
        retry=$((retry + 1))
        if [ ${retry} -lt 2 ]; then
            warn "  编译失败 (${retry}/2)，重试（-o 离线 + 跳过 clean）..."
            mvn_goal="install"
            mvn_offline="-o"
        else
            tail -60 "${log}"; die "Maven 编译失败: ${log}"
        fi
    done

    # 官方指定输出位置: war/target/jenkins.war
    war_file="${SRC_DIR}/war/target/jenkins.war"
    [ -f "${war_file}" ] || war_file=$(find "${SRC_DIR}" -name "jenkins.war" -type f 2>/dev/null | head -1)
    [ -n "${war_file}" ] && [ -f "${war_file}" ] || die "编译完成但未找到 jenkins.war"

    # 验证 WAR 是有效的 ZIP
    unzip -tq "${war_file}" 2>/dev/null || die "WAR 文件损坏: ${war_file}"

    mkdir -p "${JENKINS_DIR}"
    cp "${war_file}" "${JENKINS_WAR}"
    sha256sum "${JENKINS_WAR}" | awk '{print $1}' > "${JENKINS_WAR}.sha256"
    chmod 644 "${JENKINS_WAR}" "${JENKINS_WAR}.sha256"

    ok "WAR: ${JENKINS_WAR} ($(du -h "${JENKINS_WAR}" | cut -f1))"
}

# ── 完成 ─────────────────────────────────────────────────
_summary() {
    echo ""
    echo "============================================"
    echo "  Jenkins ${JENKINS_VERSION} 编译完成"
    echo ""
    echo "  WAR:      ${JENKINS_WAR}"
    echo "  SHA256:   $(cat "${JENKINS_WAR}.sha256" 2>/dev/null || echo 'N/A')"
    echo "  JDK:      ${JAVA_HOME}"
    echo "  大小:     $(du -h "${JENKINS_WAR}" | cut -f1)"
    echo ""
    echo "  下一步:"
    echo "    bash install_jenkins.sh       # 裸机 systemd 部署"
    echo "    bash build_image.sh --prebuilt # Docker 镜像构建"
    echo "============================================"
    echo ""
}

# ══════════════════════════════════════════════════════════
readonly LOCK_FILE="/var/run/jenkins_build.lock"

# 清理残留进程（上次异常退出可能留下）
_cleanup_stale() {
    # 检查锁文件中的 PID 是否还活着
    if [ -f "${LOCK_FILE}" ]; then
        local _stale_pid; _stale_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
        if [ -n "${_stale_pid}" ] && kill -0 "${_stale_pid}" 2>/dev/null; then
            die "已有构建进程运行中 (PID: ${_stale_pid})\n  如果确认无构建运行，请删除 ${LOCK_FILE}"
        fi
        warn "发现残留锁文件，清理中..."
        rm -f "${LOCK_FILE}"
    fi
    # 清理上次可能残留的 Maven 进程
    local _stale_mvn; _stale_mvn=$(pgrep -f "plexus.classworlds.launcher.Launcher" 2>/dev/null || true)
    if [ -n "${_stale_mvn}" ]; then
        warn "发现残留 Maven 进程 (${_stale_mvn})，终止中..."
        pkill -9 -f "plexus.classworlds.launcher.Launcher" 2>/dev/null || true
        sleep 2
        ok "已清理残留 Maven 进程"
    fi
}

# 脚本退出时释放锁
_release_lock() {
    rm -f "${LOCK_FILE}" 2>/dev/null || true
}

main() {
    # 确保输出目录存在（nohup 重定向需要）
    mkdir -p "${BUILD_DIR}" "${JENKINS_DIR}"

    echo ""; echo "============================================"
    echo "  Jenkins ${JENKINS_VERSION} 源码编译"
    echo "  JDK ${JDK_VERSION} · Maven ${MAVEN_VERSION}"
    echo "============================================"; echo ""

    # 锁机制：防止并发执行
    _cleanup_stale
    echo $$ > "${LOCK_FILE}"
    trap '_release_lock' EXIT INT TERM

    _precheck
    _ensure_jdk
    _ensure_maven

    # 持久化环境变量
    cat > /etc/profile.d/jenkins_java.sh << EOF
export JAVA_HOME=${JAVA_HOME}
export MAVEN_HOME=${MAVEN_HOME}
export PATH=\${JAVA_HOME}/bin:\${MAVEN_HOME}/bin:\${PATH}
EOF

    if [ -f "${JENKINS_WAR}" ]; then
        info "WAR 已存在: ${JENKINS_WAR} → 跳过编译"
        ok "SHA256: $(sha256sum "${JENKINS_WAR}" | awk '{print $1}')"
    else
        _fetch_source
        # 从源码 pom.xml 读取实际 JDK 要求（jenkins.zip 版本可能和参数不一致）
        local _required_jdk; _required_jdk=$(_detect_jdk_from_pom || echo "")
        if [ -n "${_required_jdk}" ] && [ "${_required_jdk}" != "${JDK_VERSION}" ]; then
            info "源码实际要求 JDK ${_required_jdk}（参数估计: ${JDK_VERSION}），切换中..."
            JDK_VERSION="${_required_jdk}"
            JAVA_HOME_TARGET="/opt/jdk${JDK_VERSION}"
            _ensure_jdk
        fi
        _compile
    fi
    _summary
}
main
