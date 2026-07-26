# Fcitx5 输入法安装文档

## 环境

- **操作系统**: CentOS Stream 9
- **桌面环境**: GNOME + Wayland
- **fcitx5 版本**: 5.0.23 (fc38 RPM)

---

## 安装步骤

### 1. 下载 RPM 包

CentOS 9 没有 el9 原生包，使用 fedora-ayatana 仓库的 fc38 编译包：

```bash
mkdir -p /tmp/fcitx5_rpms
cd /tmp/fcitx5_rpms

dnf download --repo=fedora-ayatana fcitx5 fcitx5-chinese-addons fcitx5-gtk2 fcitx5-gtk3
```

### 2. 解决 libstdc++ ABI 不兼容

fc38 的包需要 GLIBCXX_3.4.30（GCC 12+），CentOS 9 只有 GCC 11（GLIBCXX_3.4.29）。
**方案**: 不替换系统 libstdc++，将新版安装到独立目录，用 LD_LIBRARY_PATH 加载。

```bash
# 下载新版 libstdc++
curl -L -o /tmp/fcitx5_rpms/libstdc++-13.0.1-0.12.fc38.x86_64.rpm \
  "https://mirrors.huaweicloud.com/fedora/releases/38/Everything/x86_64/os/Packages/libstdc/libstdc++-13.0.1-0.12.fc38.x86_64.rpm"

# 提取到独立目录
mkdir -p /tmp/fcitx5_lib
cd /tmp/fcitx5_lib
rpm2cpio /tmp/fcitx5_rpms/libstdc++-13.0.1-0.12.fc38.x86_64.rpm | cpio -idm
mkdir -p /usr/local/lib/fcitx5
cp usr/lib64/libstdc++.so.6.0.31 /usr/local/lib/fcitx5/
cd /usr/local/lib/fcitx5 && ln -sf libstdc++.so.6.0.31 libstdc++.so.6
```

### 3. 强制安装 fcitx5

```bash
rpm -ivh --nodeps --force \
  fcitx5-5.0.23-1.fc38.x86_64.rpm \
  fcitx5-chinese-addons-5.0.17-1.fc38.x86_64.rpm \
  fcitx5-gtk2-5.0.23-1.fc38.x86_64.rpm \
  fcitx5-gtk3-5.0.23-1.fc38.x86_64.rpm
```

### 4. 配置环境变量

**`/etc/profile.d/fcitx5.sh`**（系统全局）:

```bash
export GTK_IM_MODULE=fcitx5
export QT_IM_MODULE=fcitx5
export XMODIFIERS=@im=fcitx5
export GLFW_IM_MODULE=fcitx5
```

**`~/.bashrc`**（用户 shell）:

```bash
export GTK_IM_MODULE=fcitx5
export QT_IM_MODULE=fcitx5
export XMODIFIERS=@im=fcitx5
export GLFW_IM_MODULE=fcitx5
```

**`/etc/environment`**（系统进程）:

```
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
XMODIFIERS=@im=fcitx5
GLFW_IM_MODULE=fcitx5
```

### 5. 配置拼音和快捷键

**`~/.config/fcitx5/profile`**:

```ini
[Groups/0]
Name=默认
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us

[Groups/0/Items/1]
Name=pinyin

[GroupOrder]
0=默认
```

**`~/.config/fcitx5/config`**:

```ini
[Hotkey]
TriggerKey=Control+space
[Hotkey/EnumerateForward]
0=Control+space
```

### 5.1 GNOME Wayland 专属：注册自定义快捷键

> **重要**: 在 Wayland 下 fcitx5 无法直接拦截 Ctrl+Space，必须通过 GNOME 代理。

```bash
# 清理 GNOME 残留的 ibus 输入源
gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
gsettings set org.gnome.desktop.input-sources mru-sources "[('xkb', 'us')]"

# 注册 Ctrl+Space → fcitx5 切换
CKB="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['${CKB}/custom0/']"
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${CKB}/custom0/ name 'Fcitx5 Toggle'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${CKB}/custom0/ command 'fcitx5-remote -t'
gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${CKB}/custom0/ binding '<Control>space'
```

> 注销重新登录后生效。

### 6. 开机自启

**`~/.config/autostart/fcitx5.desktop`**:

```ini
[Desktop Entry]
Name=Fcitx5
Exec=env LD_LIBRARY_PATH=/usr/local/lib/fcitx5 fcitx5 -d
Type=Application
X-GNOME-Autostart-enabled=true
NoDisplay=true
```

### 7. 禁用 ibus 输入法

```bash
# 卸载 ibus-libpinyin（保留 ibus 核心，GNOME 依赖）
dnf remove -y ibus-libpinyin

# 清理 GNOME 输入源
gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"

# 禁用 IBus daemon 自启（避免与 fcitx5 冲突）
systemctl --user disable --now ibus-daemon.service
```

### 8. 启动

```bash
export LD_LIBRARY_PATH=/usr/local/lib/fcitx5
fcitx5 -d
```

---

## 关键设计

| 问题 | 解决方案 |
|------|---------|
| libstdc++ ABI 不兼容 | 独立目录 `/usr/local/lib/fcitx5/` + `LD_LIBRARY_PATH` |
| 开机自启 | GNOME autostart `.desktop` 文件 |
| 中英文切换 | `Ctrl+Space`（fcitx5 管理，无冲突） |
| 环境变量 | 3 处写入（profile.d + bashrc + environment） |
| **GTK_IM_MODULE 必须是 `fcitx5`** | 不是 `fcitx`（那是 fcitx4 的旧值），否则 GTK 应用无法连接 fcitx5 |
| **Wayland Ctrl+Space 失灵** | GNOME 代理快捷键 `fcitx5-remote -t`，详见步骤 5.1 |
| 旧 ibus 冲突 | 卸载 ibus-libpinyin + `systemctl --user disable ibus-daemon` |

---

## 故障修复

### 快速修复脚本

```bash
bash scripts/fix_input_method.sh
```

### 常见故障排查

**1. fcitx5 进程已运行但无法输入中文**

检查环境变量 `GTK_IM_MODULE` 是否是 `fcitx5`（不是 `fcitx`）：

```bash
env | grep -iE 'fcitx|gtk_im|qt_im'
```

应为：
- `GTK_IM_MODULE=fcitx5`
- `QT_IM_MODULE=fcitx5`
- `XMODIFIERS=@im=fcitx5`

如果显示 `GTK_IM_MODULE=fcitx`，说明配置文件中写的是旧版 fcitx4 的值，需修正。

**2. IBus 与 fcitx5 冲突**

```bash
# 检查 ibus 是否在运行
systemctl --user status ibus-daemon.service

# 如果运行中，禁用它
systemctl --user disable --now ibus-daemon.service
```

**3. `~/.bashrc` 中 IBus 和 fcitx5 同时配置**

bashrc 中 fcitx5 的配置必须在 IBus 之后（后面的覆盖前面的），或者直接删除 IBus 部分。

**4. 确认 fcitx5 运行状态**

```bash
fcitx5-remote    # 返回 0 = 运行中
fcitx5-diagnose  # 完整诊断报告
```

**5. 重启 fcitx5**

```bash
pkill fcitx5
fcitx5 -d
```

## 切换方式

- **Ctrl+Space**: 中英文切换
- 右下角托盘图标: 右键可配置

## 为什么其他方式不行

| 方式 | 失败原因 |
|------|---------|
| EPEL | 无 fcitx5 包 |
| COPR | 无 el9 构建 |
| fedora-ayatana 直接安装 | libstdc++.so.6(GLIBCXX_3.4.30) 版本冲突 |
| 源码编译 | 缺 xkbcommon-devel 等 devel 包（CentOS 9 仓库无） |
| Flatpak | 无 fcitx5 |
