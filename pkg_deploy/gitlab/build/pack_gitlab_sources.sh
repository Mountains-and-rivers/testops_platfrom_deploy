#!/bin/bash
# ============================================================
# GitLab 源码包离线打包 — 在可访问 gitlab.com 的机器上执行
# 产出: gitlab-foss-*.tar.xz / gitaly-*.tar.xz 等
#
# 关键: 子组件版本从 gitlab-foss 的 VERSION 文件中读取，
#       确保与 GitLab 主应用版本精确匹配，而非盲目拉 master/main
#
# 用法: bash pack_gitlab_sources.sh [19-3-stable]
# ============================================================
set -euo pipefail

GITLAB_BRANCH="${1:-19-3-stable}"
OUTDIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo "============================================"
echo "  GitLab 源码包离线打包"
echo "  分支: ${GITLAB_BRANCH}"
echo "  输出: ${OUTDIR}"
echo "============================================"

# ── 临时目录 ──
TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

# ═══════════════════════════════════════════════
# 第 1 步: 克隆 gitlab-foss（读取 VERSION 文件）
# ═══════════════════════════════════════════════
info "克隆 gitlab-foss (${GITLAB_BRANCH})..."
git clone --depth 1 -b "${GITLAB_BRANCH}" \
    https://gitlab.com/gitlab-org/gitlab-foss.git \
    "${TMPDIR}/gitlab-foss" 
cd "${TMPDIR}/gitlab-foss"

# 读取子组件版本
GITALY_VER=$(cat GITALY_SERVER_VERSION 2>/dev/null || echo "")
SHELL_VER=$(cat GITLAB_SHELL_VERSION 2>/dev/null || echo "")
WORKHORSE_VER=$(cat GITLAB_WORKHORSE_VERSION 2>/dev/null || echo "")
PAGES_VER=$(cat GITLAB_PAGES_VERSION 2>/dev/null || echo "")
MAIN_VER=$(cat VERSION 2>/dev/null || echo "")

echo ""
echo "  GitLab FOSS 版本:   ${MAIN_VER}"
echo "  Gitaly 要求:        ${GITALY_VER}"
echo "  GitLab Shell 要求:  ${SHELL_VER}"
echo "  Workhorse 要求:     ${WORKHORSE_VER}"
echo "  Pages 要求:         ${PAGES_VER}"

# 验证版本文件非空
[ -z "${MAIN_VER}" ] && err "VERSION 文件为空，克隆可能失败"
[ -z "${GITALY_VER}" ] && err "GITALY_SERVER_VERSION 为空"

# 打包 gitlab-foss（用 VERSION 文件中的精确版本号命名）
rm -rf "${TMPDIR}/gitlab-foss/.git"
tar -cJf "${OUTDIR}/gitlab-foss-${MAIN_VER}.tar.xz" -C "${TMPDIR}/gitlab-foss" .
info "  ✓ gitlab-foss-${MAIN_VER}.tar.xz ($(du -h "${OUTDIR}/gitlab-foss-${MAIN_VER}.tar.xz" | cut -f1))"

# ═══════════════════════════════════════════════
# 第 2 步: 按精确版本克隆子组件
# ═══════════════════════════════════════════════
clone_at_version() {
    local name="$1" repo="$2" version="$3" outfile="$4"

    echo ""
    echo ">>> ${name}: ${repo} @ ${version}"

    if [ -f "${outfile}" ]; then
        echo "    已存在: ${outfile} ($(du -h "${outfile}" | cut -f1))，跳过"
        return
    fi

    local tmpdir="${TMPDIR}/${name}"
    mkdir -p "${tmpdir}"

    # 尝试按 tag 克隆，失败则按 branch，再失败尝试 commit hash
    if git clone --depth 1 -b "v${version}" "${repo}" "${tmpdir}" 2>/dev/null; then
        echo "    克隆方式: tag v${version}"
    elif git clone --depth 1 -b "${version}" "${repo}" "${tmpdir}" 2>/dev/null; then
        echo "    克隆方式: 分支 ${version}"
    else
        # commit hash 方式（如 Gitaly）：需要完整克隆再 checkout
        echo "    克隆方式: 完整仓库 → checkout ${version}"
        rm -rf "${tmpdir}"
        git clone "${repo}" "${tmpdir}"         cd "${tmpdir}"
        git checkout "${version}"         cd "${TMPDIR}"
    fi

    rm -rf "${tmpdir}/.git"
    tar -cJf "${outfile}" -C "${tmpdir}" .
    rm -rf "${tmpdir}"
    echo "    ✓ ${outfile} ($(du -h "${outfile}" | cut -f1))"
}

# ── Gitaly ──
clone_at_version "gitaly" \
    "https://gitlab.com/gitlab-org/gitaly.git" \
    "${GITALY_VER}" \
    "${OUTDIR}/gitaly-${MAIN_VER}.tar.xz"

# ── GitLab Shell ──
clone_at_version "gitlab-shell" \
    "https://gitlab.com/gitlab-org/gitlab-shell.git" \
    "${SHELL_VER}" \
    "${OUTDIR}/gitlab-shell-${MAIN_VER}.tar.xz"

# ── GitLab Workhorse ──
clone_at_version "gitlab-workhorse" \
    "https://gitlab.com/gitlab-org/gitlab-workhorse.git" \
    "${WORKHORSE_VER}" \
    "${OUTDIR}/gitlab-workhorse-${MAIN_VER}.tar.xz"

# ── GitLab Pages（可选）──
clone_at_version "gitlab-pages" \
    "https://gitlab.com/gitlab-org/gitlab-pages.git" \
    "${PAGES_VER}" \
    "${OUTDIR}/gitlab-pages-${MAIN_VER}.tar.xz"

echo ""
echo "============================================"
echo "  打包完成，产出文件:"
ls -lh "${OUTDIR}"/*.tar.xz 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
echo ""
echo "  版本摘要:"
echo "    GitLab FOSS:  ${MAIN_VER}"
echo "    Gitaly:       ${GITALY_VER}"
echo "    Shell:        ${SHELL_VER}"
echo "    Workhorse:    ${WORKHORSE_VER}"
echo "    Pages:        ${PAGES_VER}"
echo "============================================"
