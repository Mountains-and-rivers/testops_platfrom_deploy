#!/bin/bash
# =============================================================================
# IBus 看门狗 — 每 10 秒检测一次输入法状态，异常时自动修复
# 后台运行: nohup bash ibus_watchdog.sh &
# =============================================================================

LOG_FILE="/home/wgl/wgllog/ibus_watchdog.log"
mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date) 看门狗启动" >> "$LOG_FILE"

while true; do
    sleep 10

    # 检查 ibus-daemon 是否在运行
    if ! pgrep -x "ibus-daemon" > /dev/null 2>&1; then
        echo "$(date) ibus-daemon 未运行，重启中..." >> "$LOG_FILE"
        export GTK_IM_MODULE=ibus QT_IM_MODULE=ibus XMODIFIERS=@im=ibus GLFW_IM_MODULE=ibus
        ibus-daemon -drx 2>/dev/null
        sleep 2
        ibus engine libpinyin 2>/dev/null
        continue
    fi

    # 检查 libpinyin 引擎是否存活
    if ! pgrep -f "ibus-engine-libpinyin" > /dev/null 2>&1; then
        echo "$(date) libpinyin 引擎丢失，重新加载..." >> "$LOG_FILE"
        ibus engine libpinyin 2>/dev/null
    fi

    # 检查引擎是否正常响应
    CURRENT=$(ibus engine 2>/dev/null)
    if [ -z "$CURRENT" ]; then
        echo "$(date) ibus 无响应，重启..." >> "$LOG_FILE"
        pkill -9 ibus-daemon 2>/dev/null
        pkill -9 ibus-engine 2>/dev/null
        sleep 1
        ibus-daemon -drx 2>/dev/null
        sleep 2
        ibus engine libpinyin 2>/dev/null
    fi
done
