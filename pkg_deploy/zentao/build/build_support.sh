#!/bin/bash
# ============================================================
# 禅道编译辅助 Shell 脚本
# 预装 CentOS Stream 9 编译依赖（run once per build server）
# ============================================================
set -euo pipefail

echo "============================================"
echo "  禅道编译环境初始化（CentOS Stream 9）"
echo "============================================"

# 1. 安装编译依赖
echo "[1/3] 安装编译依赖..."
dnf install -y epel-release
dnf install -y \
    gcc gcc-c++ make autoconf libtool bison re2c pkgconfig \
    libxml2-devel libpng-devel libjpeg-turbo-devel freetype-devel \
    libzip-devel oniguruma-devel openssl-devel curl-devel libicu-devel \
    sqlite-devel httpd-devel wget unzip git docker

# 2. 验证关键工具
echo "[2/3] 验证编译工具..."
for cmd in gcc make wget git docker; do
    if command -v $cmd &>/dev/null; then
        echo "  ✓ $cmd: $(command -v $cmd)"
    else
        echo "  ✗ $cmd: 未安装"
        exit 1
    fi
done

# 3. 启动 Docker
echo "[3/3] 启动 Docker..."
systemctl enable docker --now 2>/dev/null || true
systemctl start docker 2>/dev/null || true
docker info >/dev/null 2>&1 && echo "  ✓ Docker 运行中" || echo "  ✗ Docker 未运行，请手动启动"

echo ""
echo "============================================"
echo "  编译环境初始化完成"
echo "============================================"
