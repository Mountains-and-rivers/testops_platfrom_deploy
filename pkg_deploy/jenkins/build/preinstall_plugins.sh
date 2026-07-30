#!/bin/bash
# ============================================================
# Jenkins 插件预下载脚本 — 从国内镜像预先下载插件
#
# 用法:
#   bash preinstall_plugins.sh                           # 下载建议插件
#   bash preinstall_plugins.sh --plugin-list "git,ldap"  # 下载指定插件
#   bash preinstall_plugins.sh --from-file plugins.txt   # 从文件读取列表
#
# 镜像:
#   MIRROR=ustc   (默认) https://mirrors.ustc.edu.cn/jenkins/plugins
#   MIRROR=tsinghua       https://mirrors.tuna.tsinghua.edu.cn/jenkins/plugins
#
# 产出:
#   插件 .jpi 文件直接写入 JENKINS_PLUGIN_DIR
# ============================================================

# 强制使用 bash
[ -z "${BASH_VERSION:-}" ] && exec bash "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" "$@"

set -euo pipefail

# ── 参数 ─────────────────────────────────────────────────
JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_PLUGIN_DIR="${JENKINS_PLUGIN_DIR:-${JENKINS_HOME}/plugins}"
UPDATE_CENTER_URL="${UPDATE_CENTER_URL:-https://updates.jenkins.io/update-center.json}"
# 预定义的"建议插件"列表（Jenkins 2.479+ 初始安装推荐）
SUGGESTED_PLUGINS="${SUGGESTED_PLUGINS:-ant,antisamy-markup-formatter,build-timeout,cloudbees-folder,credentials-binding,email-ext,git,github-branch-source,gradle,ldap,mailer,matrix-auth,pipeline-github-lib,pipeline-graph-view,pipeline-stage-view,ssh-slaves,timestamper,workflow-aggregator,ws-cleanup,dark-theme,localization-zh-cn}"

MIRROR="${MIRROR:-ustc}"
PLUGIN_LIST=""
FROM_FILE=""
FORCE="${FORCE:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plugin-list) PLUGIN_LIST="$2"; shift 2 ;;
        --from-file)   FROM_FILE="$2"; shift 2 ;;
        --force)       FORCE=true; shift ;;
        --jenkins-home) JENKINS_HOME="$2"; JENKINS_PLUGIN_DIR="${JENKINS_HOME}/plugins"; shift 2 ;;
        *) shift ;;
    esac
done

# 镜像地址
case "${MIRROR}" in
    tsinghua) MIRROR_BASE="https://mirrors.tuna.tsinghua.edu.cn/jenkins/plugins" ;;
    ustc|*)   MIRROR_BASE="https://mirrors.ustc.edu.cn/jenkins/plugins" ;;
esac

# ── UI ──────────────────────────────────────────────────
readonly R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' N='\033[0m'
info()  { echo -e "${G}[INFO]${N}  $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*"; }
step()  { echo -e "${C}[STEP]${N}  $*"; }
ok()    { echo -e "  ${G}[OK]${N} $*"; }
die()   { echo -e "\n${R}[ERROR]${N} $*"; exit 1; }

# ── 解析插件列表 ────────────────────────────────────────
if [ -n "${FROM_FILE}" ] && [ -f "${FROM_FILE}" ]; then
    PLUGIN_NAMES=$(grep -v '^#' "${FROM_FILE}" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
elif [ -n "${PLUGIN_LIST}" ]; then
    PLUGIN_NAMES="${PLUGIN_LIST}"
else
    PLUGIN_NAMES="${SUGGESTED_PLUGINS}"
fi

# 转为数组
IFS=',' read -ra PLUGIN_ARRAY <<< "${PLUGIN_NAMES}"

echo ""; echo "============================================"
echo "  Jenkins 插件预下载"
echo "  镜像: ${MIRROR_BASE}"
echo "  目标: ${JENKINS_PLUGIN_DIR}"
echo "  数量: ${#PLUGIN_ARRAY[@]} 个"
echo "============================================"; echo ""

mkdir -p "${JENKINS_PLUGIN_DIR}"

# ── 获取 update-center.json ──────────────────────────────
step "[1/3] 获取插件版本信息..."

UC_FILE="/tmp/jenkins-update-center-$$.json"

# 尝试从 Jenkins 数据目录读取缓存
if [ -f "${JENKINS_HOME}/updates/default.json" ]; then
    cp "${JENKINS_HOME}/updates/default.json" "${UC_FILE}"
    ok "使用本地缓存: ${JENKINS_HOME}/updates/default.json"
else
    info "下载 update-center.json..."
    curl -sL --connect-timeout 30 --max-time 120 \
        -o "${UC_FILE}" "${UPDATE_CENTER_URL}" || {
        warn "无法下载 update-center.json，将使用 latest 版本"
        rm -f "${UC_FILE}"
    }
    [ -f "${UC_FILE}" ] && ok "已下载 update-center.json"
fi

# ── Python 下载核心 ──────────────────────────────────────
step "[2/3] 解析版本并下载插件..."

python3 << PYEOF
import json, os, sys, re, subprocess

mirror_base = os.environ.get('MIRROR_BASE', 'https://mirrors.ustc.edu.cn/jenkins/plugins')
plugin_dir = os.environ.get('JENKINS_PLUGIN_DIR', '/var/lib/jenkins/plugins')
uc_file = '${UC_FILE}'
plugin_names = '${PLUGIN_NAMES}'.split(',')
force = '${FORCE}' == 'true'

# 解析 update-center.json（可能是 JSONP 格式）
versions = {}
if os.path.exists(uc_file):
    try:
        with open(uc_file, 'r') as f:
            raw = f.read()
        # 处理 JSONP 格式: updateCenter.post({...});
        json_str = raw
        if 'updateCenter.post(' in json_str:
            json_str = json_str.split('updateCenter.post(', 1)[1]
            if json_str.endswith(');'):
                json_str = json_str[:-2]
        data = json.loads(json_str)
        plugins = data.get('plugins', {})
        for name, info in plugins.items():
            versions[name] = info.get('version', 'latest')
    except Exception as e:
        print(f"  警告: 解析 update-center.json 失败: {e}")

ok_count = 0
skip_count = 0
fail_count = 0

for pname in plugin_names:
    pname = pname.strip()
    if not pname:
        continue

    jpi_path = os.path.join(plugin_dir, f'{pname}.jpi')
    tmp_path = os.path.join(plugin_dir, f'{pname}.jpi.tmp')

    # 已存在则跳过
    if os.path.exists(jpi_path) and not force:
        print(f"  [SKIP] {pname} (已存在)")
        skip_count += 1
        continue

    ver = versions.get(pname, 'latest')

    # 尝试指定版本下载
    url = f"{mirror_base}/{pname}/{ver}/{pname}.hpi"
    tmp_file = f"/tmp/jenkins_plugin_{pname}.hpi"

    downloaded = False
    for attempt_url in [url, f"{mirror_base}/{pname}/latest/{pname}.hpi"]:
        try:
            result = subprocess.run(
                ['curl', '-sLo', tmp_file, '-w', '%{http_code}',
                 '--connect-timeout', '30', '--max-time', '180', attempt_url],
                capture_output=True, text=True, timeout=200
            )
            if result.stdout.strip() == '200' and os.path.exists(tmp_file) and os.path.getsize(tmp_file) > 0:
                # 复制到插件目录
                os.makedirs(plugin_dir, exist_ok=True)
                # 删除旧的 .tmp 文件
                if os.path.exists(tmp_path):
                    os.remove(tmp_path)
                # 直接写入 .jpi
                with open(tmp_file, 'rb') as src:
                    with open(jpi_path, 'wb') as dst:
                        dst.write(src.read())
                size_kb = os.path.getsize(jpi_path) / 1024
                print(f"  [OK] {pname} ({size_kb:.0f} KB)")
                ok_count += 1
                downloaded = True
                break
        except Exception as e:
            continue

    if not downloaded:
        print(f"  [FAIL] {pname} (HTTP 不可达或插件不存在)")
        fail_count += 1

print(f"\n  结果: 成功={ok_count}  跳过={skip_count}  失败={fail_count}")
PYEOF

# ── 清理 ────────────────────────────────────────────────
step "[3/3] 清理..."

# 删除 update-center.json 临时文件
rm -f "${UC_FILE}"

# 删除所有损坏的 .jpi.tmp 文件
find "${JENKINS_PLUGIN_DIR}" -name '*.jpi.tmp' -delete 2>/dev/null || true
ok "已清理临时文件"

# 修复权限（如果不是 root 运行的）
if [ "$(id -u)" -eq 0 ]; then
    JENKINS_USER="${JENKINS_USER:-jenkins}"
    if id "${JENKINS_USER}" &>/dev/null 2>&1; then
        chown -R "${JENKINS_USER}:${JENKINS_USER}" "${JENKINS_PLUGIN_DIR}" 2>/dev/null && \
            ok "权限: ${JENKINS_USER}" || true
    fi
fi

# ── 完成 ────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  插件预下载完成"
echo "  插件目录: ${JENKINS_PLUGIN_DIR}"
echo "  已安装:   $(find "${JENKINS_PLUGIN_DIR}" -name '*.jpi' -not -name '*.tmp' | wc -l) 个"
echo "============================================"
