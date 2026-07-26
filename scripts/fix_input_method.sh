#!/bin/bash
# =============================================================================
# Fcitx5 输入法修复脚本 — 切换失效时运行此脚本
# 用法: bash fix_input_method.sh
# =============================================================================

echo "修复 Fcitx5 输入法..."

# 1. 环境变量
export LD_LIBRARY_PATH=/usr/local/lib/fcitx5:$LD_LIBRARY_PATH
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx5
export XMODIFIERS=@im=fcitx5

# 2. 杀掉旧进程
pkill -9 -u $USER ibus-daemon 2>/dev/null
pkill -9 -u $USER ibus-engine 2>/dev/null
pkill -9 -u $USER fcitx5 2>/dev/null
sleep 1

# 3. 清理 GNOME 输入源冲突
gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"

# 4. 启动 fcitx5
fcitx5 -d 2>/dev/null
sleep 2

# 5. 切换到拼音
fcitx5-remote -m pinyin 2>/dev/null

echo ""
echo "修复完成！"
echo "切换快捷键: Ctrl+Space"
echo "进程: $(pgrep fcitx5 > /dev/null && echo '✓ 运行中' || echo '✗ 请手动运行: fcitx5 -d')"
