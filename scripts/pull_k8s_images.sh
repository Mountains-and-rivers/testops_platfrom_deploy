#!/bin/bash
# ============================================================
# K8s 组件镜像拉取 & 保存脚本
# ============================================================
# 功能:
#   1. 从国内镜像源拉取 K8s 组件镜像
#   2. Re-tag 为官方 registry.k8s.io 名称（kubeadm 可直接识别）
#   3. 导出为 .tar 文件保存到本地 images/ 目录
#   4. 清理 containerd 中的临时镜像，避免残留
#
# 用法:
#   chmod +x pull_k8s_images.sh
#   ./pull_k8s_images.sh                           # 使用默认版本/镜像源
#   ./pull_k8s_images.sh --version 1.36.3          # 指定 K8s 版本
#   ./pull_k8s_images.sh --dry-run                 # 仅预览，不实际操作
#
# 安全设计:
#   - set -euo pipefail: 任何命令失败立即退出
#   - 每个步骤有校验，失败不继续
#   - 幂等: 已存在的 .tar 文件自动跳过
#   - trap EXIT 清理临时文件
# ============================================================

set -euo pipefail

# ---- 默认参数 ----
K8S_VERSION="${K8S_VERSION:-1.36.3}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-registry.cn-hangzhou.aliyuncs.com/google_containers}"
OFFICIAL_REGISTRY="${OFFICIAL_REGISTRY:-registry.k8s.io}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
DRY_RUN=false
RUNTIME="${RUNTIME:-containerd}"    # containerd | docker

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

# ---- 用法 ----
usage() {
    cat << EOF
用法: $0 [选项]

选项:
  --version VERSION      K8s 版本 (默认: ${K8S_VERSION})
  --mirror REGISTRY      国内镜像源 (默认: ${MIRROR_REGISTRY})
  --output DIR           输出目录 (默认: 脚本所在目录的 ../images/)
  --runtime RUNTIME      容器运行时: containerd | docker (默认: ${RUNTIME})
  --dry-run              仅预览，不实际操作
  -h, --help             显示帮助

示例:
  $0                                       # 默认版本 + 阿里云镜像
  $0 --version 1.30.6                      # 指定 K8s 版本
  $0 --mirror docker.m.daocloud.io         # 使用 DaoCloud 镜像
  $0 --runtime docker                      # 使用 Docker 而非 containerd
EOF
    exit 0
}

# ---- 解析参数 ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  K8S_VERSION="$2";  shift 2 ;;
        --mirror)   MIRROR_REGISTRY="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2";   shift 2 ;;
        --runtime)  RUNTIME="$2";      shift 2 ;;
        --dry-run)  DRY_RUN=true;      shift ;;
        -h|--help)  usage ;;
        *)          log_error "未知参数: $1"; usage ;;
    esac
done

# ---- 确定输出目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "${HOME}")"
if [[ -z "$OUTPUT_DIR" ]]; then
    # 默认输出到 Master ~/k8s-images/
    OUTPUT_DIR="$HOME/k8s-images"
fi
mkdir -p "$OUTPUT_DIR"

# ---- 临时目录 ----
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# ---- 前置检查 ----
check_prerequisites() {
    log_step "前置检查..."

    # 检查 kubeadm
    if ! command -v kubeadm &>/dev/null; then
        log_error "kubeadm 未安装，请先安装 kubeadm"
        exit 1
    fi

    # 检查容器运行时
    if [[ "$RUNTIME" == "containerd" ]]; then
        if ! command -v ctr &>/dev/null; then
            log_error "ctr 未安装，请先安装 containerd"
            exit 1
        fi
        # 检查 containerd 是否运行
        if ! ctr version &>/dev/null; then
            log_error "containerd 未运行或无权限执行 ctr（可能需要 sudo）"
            log_error "请使用 sudo 运行本脚本，或将当前用户加入 docker 组"
            exit 1
        fi
        CTR_CMD="ctr -n k8s.io"
    elif [[ "$RUNTIME" == "docker" ]]; then
        if ! command -v docker &>/dev/null; then
            log_error "docker 未安装"
            exit 1
        fi
        if ! docker info &>/dev/null; then
            log_error "docker 未运行或无权限（可能需要 sudo）"
            exit 1
        fi
        CTR_CMD="docker"
    else
        log_error "不支持的运行时: ${RUNTIME}，请使用 containerd 或 docker"
        exit 1
    fi

    log_info "kubeadm 版本: $(kubeadm version --output short 2>/dev/null || echo 'unknown')"
    log_info "容器运行时: ${RUNTIME}"
    log_info "输出目录: ${OUTPUT_DIR}"
}

# ---- 辅���函数 ----
image_name_to_tar() {
    # registry.k8s.io/kube-apiserver:v1.36.3 → kube-apiserver_v1.36.3.tar
    local image="$1"
    echo "$image" | awk -F/ '{print $NF}' | tr ':' '_'
}

pull_image() {
    local src="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] 拉取: $src"
        return 0
    fi
    log_step "拉取: $src"
    $CTR_CMD image pull "$src"
}

tag_image() {
    local src="$1" dst="$2"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Re-tag: $src → $dst"
        return 0
    fi
    log_step "Re-tag: $src → $dst"
    $CTR_CMD image tag "$src" "$dst"
}

export_image() {
    local image="$1" tar_file="$2"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] 导出: $image → $tar_file"
        return 0
    fi
    log_step "导出: $image → $tar_file"
    $CTR_CMD image export "$tar_file" "$image"
}

remove_image() {
    local image="$1"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] 删除: $image"
        return 0
    fi
    log_step "删除: $image"
    $CTR_CMD image remove "$image" 2>/dev/null || true
}

verify_tar() {
    local tar_file="$1"
    if [[ -f "$tar_file" ]] && [[ -s "$tar_file" ]]; then
        local size_kb
        size_kb=$(du -k "$tar_file" | cut -f1)
        log_info "  ├─ 文件大小: ${size_kb} KB"
        return 0
    else
        log_error "  ├─ 导出失败: 文件不存在或为空"
        return 1
    fi
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo "============================================"
    echo "  K8s 镜像拉取 & 保存工具"
    echo "============================================"
    echo "  K8s 版本:    ${K8S_VERSION}"
    echo "  镜像源:      ${MIRROR_REGISTRY}"
    echo "  官方 registry: ${OFFICIAL_REGISTRY}"
    echo "  输出目录:    ${OUTPUT_DIR}"
    echo "  运行时:      ${RUNTIME}"
    echo "============================================"
    echo ""

    check_prerequisites

    # 1. 获取镜像列表
    log_step "获取镜像清单..."
    IMAGE_LIST=$(kubeadm config images list \
        --kubernetes-version="v${K8S_VERSION}" \
        --image-repository="${OFFICIAL_REGISTRY}" 2>/dev/null) || {
        log_error "kubeadm config images list 失败"
        log_error "请确认 K8s 版本 v${K8S_VERSION} 是否有效"
        exit 1
    }

    if [[ -z "$IMAGE_LIST" ]]; then
        log_error "镜像清单为空"
        exit 1
    fi

    log_info "共 $(echo "$IMAGE_LIST" | wc -l) 个镜像:"
    echo "$IMAGE_LIST" | while read -r img; do
        echo "    • $img"
    done
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "DRY-RUN 模式，仅预览，不实际执行"
    fi

    # 2. 逐镜像处理
    local total=0 success=0 skipped=0 failed=0
    total=$(echo "$IMAGE_LIST" | wc -l)

    while IFS= read -r official_image; do
        [[ -z "$official_image" ]] && continue

        echo ""
        echo "────────────────────────────────────────────"

        # 2a. 构造国内镜像源地址
        # registry.k8s.io/kube-apiserver:v1.36.3
        # → registry.cn-hangzhou.aliyuncs.com/google_containers/kube-apiserver:v1.36.3
        mirror_image="${official_image/${OFFICIAL_REGISTRY}/${MIRROR_REGISTRY}}"

        # 2b. 确定 tar 文件名（用官方名命名）
        tar_name=$(image_name_to_tar "$official_image")
        tar_file="${OUTPUT_DIR}/${tar_name}.tar"

        # 2c. 幂等：已存在则跳过
        if [[ -f "$tar_file" ]] && [[ -s "$tar_file" ]]; then
            log_info "[跳过] ${tar_name}.tar 已存在"
            ((skipped++)) || true
            continue
        fi

        # 2d. 从国内镜像源拉取
        if ! pull_image "$mirror_image"; then
            log_warn "  拉取失败，尝试备用镜像源..."
            # 备用镜像源
            BACKUP_MIRROR="docker.m.daocloud.io"
            mirror_image_backup="${official_image/${OFFICIAL_REGISTRY}/${BACKUP_MIRROR}}"
            # DaoCloud 的路径结构不同: docker.m.daocloud.io/k8s.gcr.io/kube-apiserver:v1.36.3
            if [[ "$BACKUP_MIRROR" == "docker.m.daocloud.io" ]]; then
                mirror_image_backup="${official_image/registry.k8s.io/docker.m.daocloud.io/k8s.gcr.io}"
            fi
            if ! pull_image "$mirror_image_backup"; then
                log_error "  拉取失败（所有镜像源均不可达）: ${official_image}"
                ((failed++)) || true
                continue
            fi
            mirror_image="$mirror_image_backup"
        fi

        # 2e. Re-tag 为官方名称
        if ! tag_image "$mirror_image" "$official_image"; then
            log_error "  Re-tag 失败"
            remove_image "$mirror_image"
            ((failed++)) || true
            continue
        fi

        # 2f. 导出为 tar
        if ! export_image "$official_image" "$tar_file"; then
            log_error "  导出 tar 失败"
            ((failed++)) || true
        else
            verify_tar "$tar_file" && ((success++)) || true
        fi

        # 2g. 清理临时镜像（保留节点干净）
        remove_image "$mirror_image"   # 删除国内镜像源的 tag
        remove_image "$official_image" # 删除官方 tag（镜像层在 tar 里）

        log_info "  ✅ 完成: ${tar_name}.tar"

    done <<< "$IMAGE_LIST"

    # 3. 汇总
    echo ""
    echo "============================================"
    echo "  执行完毕"
    echo "============================================"
    echo "  总计:   ${total} 个镜像"
    echo "  成功:   ${success} 个"
    echo "  跳过:   ${skipped} 个（已存在）"
    echo "  失败:   ${failed} 个"
    echo "  输出:   ${OUTPUT_DIR}/"
    echo "============================================"

    if [[ "$failed" -gt 0 ]]; then
        log_error "有 ${failed} 个镜像拉取失败，请检查网络或镜像源"
        exit 1
    fi

    # 列出文件
    echo ""
    log_info "输出文件清单:"
    ls -lh "${OUTPUT_DIR}"/*.tar 2>/dev/null || log_warn "无 tar 文件"
    echo ""
    log_info "脚本执行完毕 ✓"
}

# ============================================================
# Calico 镜像拉取（--calico 参数触发）
# ============================================================
pull_calico_images() {
    local CALICO_VERSION="${1:-v3.27.0}"
    local CALICO_OUT="${OUTPUT_DIR:-$HOME/k8s-images}/calico"
    mkdir -p "$CALICO_OUT"

    echo ""
    echo "============================================"
    echo "  Calico ${CALICO_VERSION} 镜像拉取"
    echo "============================================"

    local IMAGES=(
        "docker.io/calico/node:${CALICO_VERSION}"
        "docker.io/calico/cni:${CALICO_VERSION}"
        "docker.io/calico/kube-controllers:${CALICO_VERSION}"
    )
    local MIRRORS=("docker.m.daocloud.io/calico" "quay.io/calico")

    for official_image in "${IMAGES[@]}"; do
        local tar_name=$(echo "$official_image" | awk -F/ '{print $NF}' | tr ':' '_')
        local tar_file="${CALICO_OUT}/${tar_name}.tar"
        [[ -f "$tar_file" && -s "$tar_file" ]] && { log_info "[跳过] ${tar_name}.tar"; continue; }

        local pulled=false
        log_info "拉取: ${official_image}"
        if $CTR_CMD image pull "$official_image" 2>&1 | grep -qE "done|unpacking"; then
            pulled=true
        else
            for m in "${MIRRORS[@]}"; do
                local tag="${official_image##*/}"
                log_info "  尝试: ${m}/${tag}"
                if $CTR_CMD image pull "${m}/${tag}" 2>&1 | grep -qE "done|unpacking"; then
                    $CTR_CMD image tag "${m}/${tag}" "$official_image" 2>/dev/null || true
                    $CTR_CMD image remove "${m}/${tag}" 2>/dev/null || true
                    pulled=true; break
                fi
            done
        fi

        if $pulled; then
            $CTR_CMD image export "$tar_file" "$official_image"
            $CTR_CMD image remove "$official_image" 2>/dev/null || true
            log_info "OK  ${tar_name}.tar ($(du -h "$tar_file" | cut -f1))"
        else
            log_error "FAIL ${official_image}"
        fi
    done
    echo ""
    log_info "Calico done | output: ${CALICO_OUT}/"
    echo "  scp root@<master>:${CALICO_OUT}/*.tar modules/k8s_cluster_deploy/images/calico/"
}

case "${1:-}" in
    --calico) pull_calico_images "${2:-v3.27.0}" ;;
    *)        main "$@" ;;
esac
