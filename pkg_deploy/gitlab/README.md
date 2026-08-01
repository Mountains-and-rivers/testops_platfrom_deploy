# GitLab CE 部署

> Omnibus RPM / Docker 容器 / 源码构建（CentOS 9），三种方式可选

---

## 一键执行

### 方式 1：Omnibus RPM（生产推荐，裸机安装）

```bash
# 第 1 步：下载 RPM 包
bash build/build_gitlab.sh omnibus 19.3.0-pre

# 第 2 步：安装启动（首次 reconfigure 约 5-10 分钟）
bash build/install_gitlab.sh omnibus 19.3.0-pre 192.168.0.104

# 访问
#   http://192.168.0.104
#   账号: root  密码: Gitlab12345
```

### 方式 2：Docker 容器化

```bash
# 第 1 步：准备镜像（本地 tar 优先）
bash build/build_gitlab.sh docker 19.3.0-pre

# 第 2 步：启动容器（首次初始化 3-5 分钟）
bash build/install_gitlab.sh docker 19.3.0-pre 192.168.0.104
```

### 方式 3：源码构建（CentOS 9，二次开发/定制）

```bash
# 前置：PostgreSQL 16 + Redis 7
bash ../postgresql18/install_postgresql.sh
bash ../redis7/install_redis.sh

# 第 1 步：编译构建（~30-60 分钟）
bash build/build_gitlab_source.sh 19-3-stable

# 第 2 步：初始化 DB + 编译前端 + 启动
bash build/install_gitlab_source.sh
```

---

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| 模式 | `omnibus` / `docker` / `source` | omnibus |
| 版本 | GitLab CE 版本号 | 19.3.0-pre |
| 域名/IP | 外部访问地址 | gitlab.testops.local |
| `--port` | HTTP 端口 | 80 |
| `--pass` | root 初始密码 | Gitlab12345 |
| `--skip-ruby` | 跳过 Ruby 编译（源码模式） | false |
| `--skip-go` | 跳过 Go 编译（源码模式） | false |

---

## 原理

```
Omnibus 模式:
  gitlab-ce-*.rpm (官方包)
    ├── 内嵌 PostgreSQL / Redis / Nginx / Puma
    ├── gitlab-ctl reconfigure → 自动配置所有组件
    └── 单机全栈，维护简单

Docker 模式:
  gitlab/gitlab-ce:19.3.0-pre (官方镜像 / 本地 tar)
    ├── Omnibus 打包为容器
    └── 数据卷: /data/gitlab/{config,logs,data}

源码构建模式:
  gitlab-foss (Ruby/Rails) + gitaly (Go) + gitlab-shell (Go) + workhorse (Go)
    ├── rake task 自动 clone & compile 子组件
    ├── 依赖: Ruby 3.3.x / Go 1.22.x / Node 20.x
    └── 官方仅支持 Debian/Ubuntu，本脚本适配 CentOS 9
```

---

## 数据库 & Redis 连接配置

脚本在 `build_gitlab_source.sh` Step 11 自动配置：

| 配置项 | 文件 | 值 |
|--------|------|-----|
| PostgreSQL 连接 | `config/database.yml` | `postgres:Pg1@zendao2024@127.0.0.1` |
| Redis（后台任务） | `config/resque.yml` | `redis://:Pg1@zendao2024@127.0.0.1:6379` |
| Redis（ActionCable） | `config/cable.yml` | `redis://:Pg1@zendao2024@127.0.0.1:6379` |

如 PG/Redis 密码不同，安装后修改对应文件：

```bash
cd /home/git/gitlab
sudo -u git -H vim config/database.yml   # PostgreSQL
sudo -u git -H vim config/resque.yml     # Redis
sudo -u git -H vim config/cable.yml      # Redis
```

---

## 源码构建 — 仓库清单

| # | 组件 | 语言 | 仓库地址 | 获取方式 |
|---|------|------|---------|---------|
| 1 | GitLab FOSS | Ruby/Rails | `https://gitlab.com/gitlab-org/gitlab-foss.git` | git clone |
| 2 | Gitaly | Go | `https://gitlab.com/gitlab-org/gitaly.git` | rake task 自动 |
| 3 | GitLab Shell | Go | `https://gitlab.com/gitlab-org/gitlab-shell.git` | rake task 自动 |
| 4 | GitLab Workhorse | Go | `https://gitlab.com/gitlab-org/gitlab-workhorse.git` | rake task 自动 |
| 5 | GitLab Pages（可选） | Go | `https://gitlab.com/gitlab-org/gitlab-pages.git` | 手动 clone |

**GitHub 镜像（仅部分组件有）：**

| 组件 | GitHub 地址 | 状态 |
|------|-----------|------|
| GitLab FOSS | `https://github.com/gitlabhq/gitlabhq.git` | ✅ |
| GitLab Shell | `https://github.com/gitlabhq/gitlab-shell.git` | ✅ |
| Gitaly | — | ❌ 无 GitHub 镜像 |
| Workhorse | — | ❌ 无 GitHub 镜像 |

---

## 源码构建 — 语言运行时

| 组件 | 版本 | 下载地址 | 大小 |
|------|------|---------|------|
| Ruby | 3.3.9 | `https://cache.ruby-lang.org/pub/ruby/3.3/ruby-3.3.9.tar.gz` | ~20MB |
| Go | 1.26.4 | `https://go.dev/dl/go1.26.4.linux-amd64.tar.gz` | ~66MB |
| Node.js | 22.20.0 | `https://nodejs.org/dist/v22.20.0/node-v22.20.0-linux-x64.tar.xz` | ~29MB |

---

## 源码构建 — 系统依赖（CentOS 9）

| CentOS 9 包 | 对应 Debian 包 | 用途 |
|-------------|---------------|------|
| `gcc gcc-c++ make` | `build-essential` | C/C++ 编译工具链 |
| `cmake pkg-config autoconf automake` | `cmake pkg-config ...` | 构建系统 |
| `meson ninja-build` | `meson ninja-build` | Gitaly 构建（GitLab 19.x 新增） |
| `git curl wget patch tar bzip2 xz` | `git curl ...` | 源码获取 & 解压 |
| `zlib-devel` | `zlib1g-dev` | 压缩库 |
| `openssl-devel` | `libssl-dev` | SSL/TLS |
| `readline-devel` | `libreadline-dev` | Ruby 命令行编辑 |
| `libxml2-devel` | `libxml2-dev` | XML 解析（Nokogiri） |
| `libxslt-devel` | `libxslt-dev` | XSLT 处理 |
| `libicu-devel` | `libicu-dev` | Unicode 国际化（charlock_holmes） |
| `libcurl-devel` | `libcurl4-openssl-dev` | HTTP 客户端 |
| `expat-devel` | `libexpat1-dev` | XML 解析 |
| `pcre2-devel` | `libpcre2-dev` | 正则表达式（Git） |
| `libyaml-devel` | `libyaml-dev` | YAML 解析 |
| `libffi-devel` | `libffi-dev` | 外部函数接口 |
| `gdbm-devel` | `libgdbm-dev` | 键值数据库 |
| `re2-devel` | `libre2-dev` | 正则引擎 |
| `ncurses-devel` | `libncurses5-dev` | 终端 UI |
| `perl-Image-ExifTool` | `libimage-exiftool-perl` | Workhorse 图片 EXIF 剥离 |
| `postgresql-devel` | `libpq-dev` | pg gem 原生扩展编译 |
| `krb5-devel` | `libkrb5-dev` | GSSAPI 认证头文件（gitlab-shell 编译需要） |
| `postfix` | `postfix` | 邮件发送 |

**运行时（已有独立安装脚本）：**

| 组件 | 脚本 | 最低版本 |
|------|------|---------|
| PostgreSQL 18+ | `../postgresql18/install_postgresql.sh` | 18.x |
| Redis 7+ | `../redis7/install_redis.sh` | 7.x |

---

## 目录结构

```
gitlab/
├── README.md
├── .gitignore
├── filelist.txt
├── build/
│   ├── build_gitlab.sh          # Omnibus + Docker 准备
│   ├── build_gitlab_source.sh   # 源码构建（CentOS 9）
│   ├── install_gitlab.sh        # Omnibus + Docker 安装
│   ├── clean_gitlab.sh          # 卸载清理
│   ├── Dockerfile               # Docker 定制模板
│   └── gitlab.rb.template       # Omnibus 配置模板
├── manifests/                   # K8s 部署清单（预留）
├── workflow/                    # Python 工作流（预留）
└── verify/                      # 健康校验（预留）
```

---

## 卸载清理

```bash
# Omnibus RPM 卸载
bash build/clean_gitlab.sh omnibus

# Docker 卸载
bash build/clean_gitlab.sh docker

# 源码构建卸载（含 /home/git/* /usr/local/ruby /usr/local/go）
bash build/clean_gitlab.sh source

# 任意模式 + 删除数据目录 + 数据库 + git 用户
bash build/clean_gitlab.sh source --data
```

| 模式 | 清理范围 |
|------|---------|
| `omnibus` | RPM 包 + /opt/gitlab + /var/opt/gitlab + /etc/gitlab |
| `docker` | 容器 + 镜像 |
| `source` | systemd 服务 + /home/git/* + /usr/local/ruby + /usr/local/go + Node 二进制 |
| `--data` | 附加清理 /data/gitlab + 数据库 gitlabhq_production + git 用户 |

---

## 离线部署

### 源码构建所需文件

将以下文件放入 `build/` 目录，脚本自动使用本地文件。**版本必须精确匹配**，
由 `pack_gitlab_sources.sh` 从 `19-3-stable` 的 VERSION 文件自动确定。

| 文件 | 大小 | 获取方式 |
|------|------|---------|
| `gitlab-foss-19.3.0-pre.tar.xz` | ~115MB | `bash pack_gitlab_sources.sh 19-3-stable`（含 workhorse） |
| `gitaly-19.3.0-pre.tar.xz` | ~4.3MB | 同上，自动按 `GITALY_SERVER_VERSION`(commit 49c6beca) 克隆 |
| `gitlab-shell-19.3.0-pre.tar.xz` | ~200KB | 同上，自动按 `GITLAB_SHELL_VERSION`(v14.56.1) 克隆 |
| `gitlab-pages-19.3.0-pre.tar.xz` | ~222KB | 同上，自动按 `GITLAB_PAGES_VERSION`(commit 2d40411) 克隆（可选） |
| `ruby-3.3.9.tar.gz` | ~20MB | `https://cache.ruby-lang.org/pub/ruby/3.3/ruby-3.3.9.tar.gz` |
| `go1.26.4.linux-amd64.tar.gz` | ~66MB | `https://go.dev/dl/go1.26.4.linux-amd64.tar.gz` |
| `node-v22.20.0-linux-x64.tar.xz` | ~29MB | `https://nodejs.org/dist/v22.20.0/node-v22.20.0-linux-x64.tar.xz` |

### 版本要求对照 (GitLab 19.3)

| 组件 | 要求版本 | 变量名 | 来源 |
|------|---------|--------|------|
| Ruby | 3.3.9 | `RUBY_VERSION` | 手动下载 |
| Go | 1.26.4 | `GO_VERSION` | 手动下载 |
| Node.js | 22.20.0 | `NODE_VERSION` | 手动下载 |
| Gitaly | commit 49c6beca | `GITALY_SERVER_VERSION` | 从 gitlab-foss 读取 |
| GitLab Shell | v14.56.1 | `GITLAB_SHELL_VERSION` | 从 gitlab-foss 读取 |
| Workhorse | 含于 gitlab-foss 包内 | `GITLAB_WORKHORSE_VERSION` | 从 gitlab-foss 读取 |
| Pages | commit 2d40411 | `GITLAB_PAGES_VERSION` | 从 gitlab-foss 读取 |

> **注意**: 源码包不能用 master/main 分支打包！`pack_gitlab_sources.sh` 会先克隆 gitlab-foss，
> 读取其 VERSION 文件获取子组件精确版本，再按该版本打包。

### Omnibus / Docker 所需文件

| 文件 | 大小 | 用途 | 模式 |
|------|------|------|------|
| `gitlab-ce-19.3.0-pre-ce.0.el9.x86_64.rpm` | ~1.2GB | Omnibus RPM | omnibus |
| `gitlab-ce-19.3.0-pre.tar.gz` | ~1.0GB | Docker 镜像 tar | docker |

下载地址：
- RPM: `https://mirrors.tuna.tsinghua.edu.cn/gitlab-ce/yum/el9/`
- Ruby: `https://cache.ruby-lang.org/pub/ruby/3.3/`
- Go: `https://go.dev/dl/`
- Node.js: `https://nodejs.org/dist/v22.20.0/`

---

## 端口

| 端口 | 用途 |
|------|------|
| 80 (可配) | HTTP Web UI + API |
| 2222 (Docker) | SSH Git 克隆（映射到容器 22） |

---

## 系统要求

| 资源 | Omnibus | Docker | 源码构建 |
|------|---------|--------|---------|
| CPU | 2 Cores | 2 Cores | 4+ Cores |
| 内存 | 4 GB | 4 GB | **8 GB（最低）/ 16 GB（建议）** |
| 磁盘 | 20 GB | 20 GB | 50+ GB

> ⚠️ **内存说明（重要）**  
> GitLab 官方要求源码安装最低 **8 GB RAM**。前端资源编译（webpack）是内存峰值最高的阶段，  
> package.json 中默认 `NODE_OPTIONS="--max-old-space-size=10240"`（10 GB 堆）。  
>   
> **安装脚本已自动处理：**  
> - 编译前自动 stop Puma / Sidekiq / Workhorse 释放内存  
> - **自适应 Node 堆**：按公式 `(物理内存 + Swap) × 60%` 自动计算，min 4096 / max 8192  
> - 支持手动覆盖：`NODE_HEAP_MB=7168 bash install_gitlab_source.sh`  
>
> **计算公式：`_NODE_HEAP = (RAM(GB) + Swap(GB)) × 60% × 1024` MB**
>
> | 机器配置 | 虚拟内存 | Node 堆 | 能否编译 |
> |----------|---------|---------|---------|
> | 16 GB + 0 swap | 16 GB | 8192 MB | ✅ 富余 |
> | 12 GB + 0 swap | 12 GB | 7372 MB | ✅ 正常 |
> | 8 GB + 4 GB swap | 12 GB | 7372 MB | ✅ swap 起关键作用 |
> | 9 GB + 4 GB swap | 13 GB | 7987 MB | ✅ 实测通过 |
> | 9 GB + 2 GB swap | 11 GB | 6758 MB | ⚠️ 可能 OOM |
> | 9 GB + 0 swap | 9 GB | 4096 MB | ❌ 必 OOM |
> | < 8 GB + 0 swap | < 8 GB | 4096 MB | ❌ 不建议尝试 |
>
> **核心结论：Swap 是关键杠杆，不是辅助。**  
> webpack 编译需要 ~7 GB 真实堆内存，9 GB 物理机必须加 4 GB swap 才能达标。  
> 虚拟内存 < 10 GB 时脚本会自动打印警告。
>
> **Swap 操作（必须执行）：**  
> ```bash
> # 4 GB swap（推荐，9 GB 机器上编译必需）
> dd if=/dev/zero of=/swapfile bs=1M count=4096
> chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
> echo '/swapfile none swap defaults 0 0' >> /etc/fstab  # 持久化
> ```
>
> **编译失败诊断：**  
> 脚本会自动区分三类错误，输出不同提示：
> - **CRLF 残留** → 自动清理后重试
> - **Node 堆溢出** (`SIGABRT`) → 增加 swap 或手动指定 `NODE_HEAP_MB`
> - **系统 OOM Kill** (`SIGKILL`) → 虚拟内存不足，必须增加 swap
>
> **已知问题：CRLF 换行符**  
> 源码包在 Windows 解压后可能残留 `\r` 换行符，导致 `Permission denied`。  
> 安装脚本启动时自动检测并清理 `scripts/` `bin/` `config/` 目录下的 CRLF 文件。
