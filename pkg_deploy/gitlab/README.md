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
# 前置：PostgreSQL 18 + Redis 7
bash ../postgresql18/install_postgresql.sh --for-gitlab
bash ../redis7/install_redis.sh

# 第 1 步：编译构建（~30-60 分钟，需 ≥12GB 虚拟内存）
bash build/build_gitlab_source.sh 19-3-stable

# 第 2 步：初始化 DB + 编译前端 + 启动（~15-40 分钟）
bash build/install_gitlab_source.sh 192.168.10.6

# 访问: http://192.168.10.6
# 账号: root  密码: Gitlab12345
```

### 方式 4：预编译包部署（批量部署，跳过编译）

```bash
# 前置：将编译好的产物放入 gitlab_pkg/ 目录
#       PostgreSQL 18 + Redis 7 已安装运行

# 一键部署启动（~3-5 分钟）
bash start_gitlab.sh 192.168.10.6

# 访问: http://192.168.10.6
# 账号: root  密码: Gitlab12345
```

### 安装完成后如何访问

| 安装方式 | 访问地址 | 说明 |
|---------|---------|------|
| Omnibus RPM | `http://<IP>` | Nginx 内嵌，开箱即用 |
| 源码构建 | `http://<IP>` | 脚本自动安装 Nginx + 反代配置 |
| 预编译包 | `http://<IP>` | 同源码构建 |

> **⚠️ 必须用 80 端口访问，不要用 `:3000`！**  
> Puma 在 3000 端口运行 Rails，但生产模式下**不提供 CSS/JS/字体等静态文件**。  
> 直接访问 `:3000` 会看到页面布局错乱、一堆 MIME type 错误。  
> 正确方式是通过 Nginx 80 端口，Nginx 负责 `/assets/` 静态文件直出 + 动态请求代理到 Workhorse。

---

## 访问验证 & 故障排查

### 第一步：确认服务都在运行

```bash
# 所有 GitLab 组件 + Nginx 应为 active
systemctl is-active gitlab-gitaly gitlab-workhorse gitlab-puma gitlab-sidekiq nginx
```

### 第二步：确认端口在监听

```bash
ss -tlnp | grep -E ':(80|3000)'
```

正常输出应包含：
- `0.0.0.0:80` → nginx
- `*:3000` → bundle/puma

### 第三步：命令行测试 HTTP 响应

```bash
# Nginx 80 端口（正常返回 302 重定向到登录页）
curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1/

# CSS 静态文件（正常返回 200 + Content-Type: text/css）
curl -sk -I http://127.0.0.1/assets/ 2>/dev/null | head -5
```

### 第四步：浏览器访问

```
http://<服务器IP>
```

首次访问流程：
1. 浏览器打开 → 302 跳转到 `/users/sign_in`
2. 如果没有 root 密码 → 跳转到 `/admin/initial_setup/new` 设置密码
3. 设置密码后进入登录页 → 用户名 `root`

---

## 常见访问问题

### 页面返回 502 / "Waiting for GitLab to boot"

**原因**：Workhorse 无法连接到 Puma。

```bash
# 检查 Workhorse 后端配置
grep authBackend /etc/systemd/system/gitlab-workhorse.service

# 应显示: -authBackend http://127.0.0.1:3000
# 如果显示 8080，执行修复:
sed -i 's|-authBackend http://127.0.0.1:8080|-authBackend http://127.0.0.1:3000|' /etc/systemd/system/gitlab-workhorse.service
systemctl daemon-reload && systemctl restart gitlab-workhorse
```

### 页面加载出来了但 CSS/JS/图标全坏（MIME type 错误）

**原因 1**：你访问的是 `http://IP:3000` 而不是 `http://IP`。Puma 在生产模式不提供静态文件。

→ **解决**：改用 `http://<IP>`（80 端口）访问。

**原因 2**：Nginx 配置缺少 `/assets/` 静态直出块。

```bash
# 检查配置是否包含 assets 块
grep -A3 "location /assets" /etc/nginx/conf.d/gitlab.conf

# 如果没有，手动添加后 reload：
sed -i '/location \/ {/i\    location /assets/ {\n        gzip_static on;\n        expires max;\n        add_header Cache-Control public;\n    }\n' /etc/nginx/conf.d/gitlab.conf
nginx -t && systemctl reload nginx
```

### 页面 403 Forbidden

**原因**：Nginx 默认 server block 抢在 gitlab 配置之前匹配，或 nginx 用户无权限访问 git 目录。

```bash
# 修复 1：确保 gitlab.conf 使用 default_server
grep 'default_server' /etc/nginx/conf.d/gitlab.conf || \
  sed -i 's/listen 80;/listen 80 default_server;/' /etc/nginx/conf.d/gitlab.conf

# 修复 2：nginx 用户加入 git 组
usermod -a -G git nginx
chmod g+x /home/git
systemctl restart nginx
```

### 页面 404 Not Found

```bash
# 检查前端资源是否已编译
ls /home/git/gitlab/public/assets/ | wc -l
# 应该有数百个文件，如果为空则需要重新编译前端资源
```

### 整体诊断命令

```bash
# 一键输出全部关键信息
echo "=== 服务状态 ===" && for s in gitlab-gitaly gitlab-workhorse gitlab-puma gitlab-sidekiq nginx; do echo -n "$s: "; systemctl is-active $s; done
echo "=== 端口 ===" && ss -tlnp | grep -E ':(80|3000)'
echo "=== Workhorse 后端 ===" && grep authBackend /etc/systemd/system/gitlab-workhorse.service
echo "=== Nginx assets ===" && grep -A3 "location /assets" /etc/nginx/conf.d/gitlab.conf
echo "=== Nginx 权限 ===" && groups nginx && stat -c "%a %n" /home/git
echo "=== HTTP 测试 ===" && curl -sk -o /dev/null -w "Nginx:80 → %{http_code}\n" http://127.0.0.1/ && curl -sk -o /dev/null -w "Puma:3000 → %{http_code}\n" http://127.0.0.1:3000/
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

## 服务架构 & 组件通信

### 请求流转全景

```
                          Browser / Git Client
                                  │
                         http://<IP>:80
                                  │
                                  ▼
                     ┌─────────────────────┐
                     │       Nginx         │  ← 反向代理入口
                     │      (port 80)      │     静态文件 /assets/ 直出
                     └──────┬──────┬───────┘
                            │      │
              /assets/ 直出  │      │  /* 动态请求
              (gzip_static)  │      │  proxy_pass
                            │      ▼
                            │  ┌──────────────────────┐
                            │  │     Workhorse        │  ← Git over HTTP 代理
                            │  │  (unix socket:       │     请求鉴权 / 预处理
                            │  │   gitlab-workhorse   │     LFS / 文件上传
                            │  │   .socket)           │
                            │  └──────────┬───────────┘
                            │             │ authBackend
                            │             │ http://127.0.0.1:3000
                            │             ▼
                            │  ┌──────────────────────┐
                            └─►│        Puma          │  ← Rails Web 应用
                               │    (port 3000)       │     API / Web UI
                               └──┬──────┬──────┬─────┘
                                  │      │      │
                         ┌────────┘      │      └─────────┐
                         ▼               ▼                ▼
              ┌──────────────────┐ ┌──────────┐ ┌──────────────────┐
              │     Gitaly       │ │ Sidekiq  │ │  PostgreSQL 16+ │
              │ (unix socket:    │ │(后台任务) │ │  (port 5432)    │
              │  gitaly.socket)  │ │          │ │                  │
              └────────┬─────────┘ └──────────┘ └──────────────────┘
                       │
                       ▼
              ┌──────────────────┐ ┌──────────────────┐
              │  Git 仓库存储    │ │    Redis 7+      │
              │ /home/git/       │ │  (port 6379)     │
              │ repositories/    │ │  缓存/队列/      │
              └──────────────────┘ │  ActionCable     │
                                   └──────────────────┘
```

### 组件职责与通信方式

| 组件 | 端口/路径 | 通信对象 | 协议 | 职责 |
|------|----------|---------|------|------|
| **Nginx** | `:80` | ← Client | HTTP | 反向代理、静态资源直出、请求转发 |
| **Workhorse** | `unix:sockets/gitlab-workhorse.socket` | ← Nginx → Puma | HTTP/unix | Git HTTP 代理、鉴权注入、大文件上传 |
| **Puma** | `:3000` | ← Workhorse → PG/Redis/Gitaly | HTTP | Rails Web 应用、API、页面渲染 |
| **Sidekiq** | — | → PG/Redis/Gitaly | — | 异步任务（邮件、Pipeline 作业、仓库清理） |
| **Gitaly** | `unix:sockets/private/gitaly.socket` | ← Puma/Sidekiq → Git | gRPC | Git 仓库 RPC 操作 |
| **PostgreSQL** | `:5432` | ← Puma/Sidekiq | TCP | 持久化存储（用户、项目、Issue 等） |
| **Redis** | `:6379` | ← Puma/Sidekiq/Workhorse | TCP | 缓存、Sidekiq 队列、实时通知 |

### 服务启动顺序 & 依赖关系

```
  [1] postgresql ──┐
  [1] redis ───────┤
                   ├──► [3] gitlab-puma ──► [4] gitlab-sidekiq
  [2] gitlab-gitaly┘           │
                               ▼
                   [5] gitlab-workhorse
                               │
                               ▼
                   [6] nginx
```

| 顺序 | 服务 | 依赖 | 说明 |
|:----:|------|------|------|
| 1 | **postgresql** + **redis** | 无 | 基础数据层，必须先启动 |
| 2 | **gitlab-gitaly** | 无 | Git RPC 服务，独立启动 |
| 3 | **gitlab-puma** | PG + Redis + Gitaly | Rails 应用，需等待 PG/Redis 就绪 |
| 4 | **gitlab-sidekiq** | PG + Redis | 后台任务，可与 Puma 并行 |
| 5 | **gitlab-workhorse** | Puma | 代理层，依赖 Puma authBackend |
| 6 | **nginx** | Workhorse | 入口反向代理，最后启动 |

### 一键查看所有服务状态

```bash
for s in postgresql redis gitlab-gitaly gitlab-puma gitlab-sidekiq gitlab-workhorse nginx; do
    echo -n "$s: "; systemctl is-active $s 2>/dev/null || echo "not-found"
done
```

预期全部输出 `active`。

### 查看各组件日志

| 组件 | 日志位置 | 实时查看命令 |
|------|---------|------------|
| Nginx | `/var/log/nginx/gitlab_access.log` / `gitlab_error.log` | `tail -f /var/log/nginx/gitlab_error.log` |
| Workhorse | systemd journal | `journalctl -u gitlab-workhorse -f` |
| Puma | `/home/git/gitlab/log/puma.stderr.log` | `tail -f /home/git/gitlab/log/puma.stderr.log` |
| Puma (生产) | `/home/git/gitlab/log/production_json.log` | `tail -f /home/git/gitlab/log/production_json.log` |
| Sidekiq | systemd journal | `journalctl -u gitlab-sidekiq -f` |
| Gitaly | systemd journal | `journalctl -u gitlab-gitaly -f` |
| Rails 异常 | `/home/git/gitlab/log/exceptions_json.log` | `tail -f /home/git/gitlab/log/exceptions_json.log` |
| gRPC 调用 | `/home/git/gitlab/log/grpc.log` | `tail -f /home/git/gitlab/log/grpc.log` |

---

## 数据持久化 & 存储架构

### 各组件存储职责

```
┌─────────────────────────────────────────────────────────┐
│                    GitLab 存储全景                        │
├──────────┬──────────────┬──────────────┬────────────────┤
│  组件     │  数据类型     │  存储路径     │  存储引擎       │
├──────────┼──────────────┼──────────────┼────────────────┤
│ PostgreSQL│ 用户/项目/   │ /var/lib/    │ PostgreSQL 16+  │
│          │ Issue/MR/    │ pgsql/data/  │ 单库 ~5-10GB   │
│          │ CI/CD/Snippet│              │                │
├──────────┼──────────────┼──────────────┼────────────────┤
│ Gitaly   │ Git 仓库     │ /home/git/   │ 文件系统        │
│          │ (.git 对象)  │ repositories/│ 每个仓库独立目录 │
├──────────┼──────────────┼──────────────┼────────────────┤
│ Rails    │ 上传文件      │ /data/gitlab/│ 本地文件系统    │
│ (Puma)   │ 附件/头像    │ uploads/     │                │
│          │ CI 产物      │ artifacts/   │                │
│          │ 容器镜像     │ registry/    │                │
│          │ Pages 站点   │ pages/       │                │
│          │ Terraform    │ terraform_   │                │
│          │ 状态         │ state/       │                │
├──────────┼──────────────┼──────────────┼────────────────┤
│ Redis    │ 缓存/Session │ 内存 (+ RDB) │ Redis 7+       │
│          │ Sidekiq 队列 │ /var/lib/    │ 重启后缓存丢失  │
│          │ ActionCable  │ redis/       │ (不影响数据)   │
├──────────┼──────────────┼──────────────┼────────────────┤
│ Nginx    │ 访问日志     │ /var/log/    │ 文本文件        │
│          │ 错误日志     │ nginx/       │ 需日志轮转      │
└──────────┴──────────────┴──────────────┴────────────────┘
```

### 持久化数据详细清单

| 优先级 | 数据 | 路径 | 大小参考 | 备份方式 |
|:---:|------|------|------|------|
| ⭐⭐⭐ | **数据库** | PostgreSQL `gitlabhq_production` | 5-50 GB | `pg_dump -U postgres gitlabhq_production > backup.sql` |
| ⭐⭐⭐ | **Git 仓库** | `/home/git/repositories/` | 1-500 GB | `rsync -a /home/git/repositories/ backup:/` |
| ⭐⭐⭐ | **上传文件** | `/data/gitlab/uploads/` | 1-100 GB | rsync / tar |
| ⭐⭐ | **配置文件** | `/home/git/gitlab/config/` | < 1 MB | git 版本管理 |
| ⭐⭐ | **加密密钥** | `secrets.yml` `.gitlab_shell_secret` `.gitlab_workhorse_secret` | < 1 KB | 加密备份 |
| ⭐ | **CI Artifacts** | `/data/gitlab/artifacts/` | 1-100 GB | 可过期清理 |
| ⭐ | **容器 Registry** | `/data/gitlab/registry/` | 1-200 GB | rsync |
| ⭐ | **Pages 站点** | `/data/gitlab/pages/` | < 10 GB | 可重建 |
| — | **Nginx 日志** | `/var/log/nginx/` | 1-10 GB | logrotate 自动轮转 |
| — | **GitLab 日志** | `/home/git/gitlab/log/` | 1-5 GB | logrotate |
| — | **Redis 数据** | 内存 | < 2 GB | 重启自动重建（无需备份） |

### 磁盘分区建议

```
/                      40 GB    系统 + GitLab 代码 + vendor/bundle + node_modules
/home                  100+ GB  Git 仓库 + Gitaly 元数据
/data                  50+ GB   上传 / CI / Registry / Pages
/var                   30 GB    PostgreSQL 数据 + 日志
swap                   8 GB     编译 webpack 时需要，运行期建议禁用
```

> GitLab 源码安装后 `/home/git/gitlab/` 约 **5-8 GB**（含 vendor/bundle + node_modules + public/assets）

### 备份优先级

```bash
# 1. 数据库（最重要 — 丢失 = 全部元数据丢失）
pg_dump -U postgres -Fc gitlabhq_production > gitlab_db_$(date +%Y%m%d).dump

# 2. Git 仓库（核心资产）
rsync -a /home/git/repositories/ backup-server:/gitlab/repos/

# 3. 配置文件 + 密钥
tar -czf gitlab_config_$(date +%Y%m%d).tgz /home/git/gitlab/config/ /home/git/gitlab/.gitlab_*

# 4. 上传文件（附件、头像）
rsync -a /data/gitlab/uploads/ backup-server:/gitlab/uploads/
```

### 关键配置文件

| 文件 | 作用 | 变更后操作 |
|------|------|-----------|
| `/home/git/gitlab/config/gitlab.yml` | 域名、Gitaly 地址、Workhorse 密钥 | `systemctl restart gitlab-puma` |
| `/home/git/gitlab/config/database.yml` | PG 连接 | `systemctl restart gitlab-puma` |
| `/home/git/gitlab/config/puma.rb` | Puma 端口/worker/线程 | `systemctl restart gitlab-puma` |
| `/home/git/gitlab/config/resque.yml` | Redis (Sidekiq) | `systemctl restart gitlab-sidekiq` |
| `/home/git/gitlab/config/cable.yml` | Redis (ActionCable) | `systemctl restart gitlab-puma` |
| `/home/git/gitlab/config/secrets.yml` | 加密密钥 | **不可变更**（变更后所有 session 失效） |
| `/home/git/gitlab/.gitlab_shell_secret` | Shell + Gitaly token | `systemctl restart gitlab-gitaly` |
| `/home/git/gitlab/.gitlab_workhorse_secret` | Workhorse 密钥 | `systemctl restart gitlab-workhorse` |
| `/home/git/gitaly/config.toml` | Gitaly 仓库路径/token | `systemctl restart gitlab-gitaly` |
| `/etc/nginx/conf.d/gitlab.conf` | Nginx 反代 | `nginx -t && systemctl reload nginx` |

### token 一致性（重要）

以下三个位置的 Gitaly token **必须完全一致**，否则出现 500 / hmac 错误：

1. `gitaly_token` in `/home/git/gitlab/.gitlab_shell_secret`
2. `token` in `/home/git/gitaly/config.toml` → `[auth]` 段
3. `token` in `/home/git/gitlab/config/gitlab.yml` → 生产 `gitaly:` 段

```bash
# 检查 token 是否一致
echo "shell:  $(grep gitaly_token /home/git/gitlab/.gitlab_shell_secret)"
echo "gitaly: $(grep token /home/git/gitaly/config.toml)"
echo "yml:    $(grep -A3 'gitaly:' /home/git/gitlab/config/gitlab.yml | grep token | head -1)"
```

### 预编译包位置

| 内容 | 路径 |
|------|------|
| 本地包目录 | `gitlab_pkg/` |
| 包内 GitLab 源码 | `gitlab_pkg/gitlab/` |
| 包内 Gitaly | `gitlab_pkg/gitaly/` |
| 包内 Workhorse | `gitlab_pkg/gitlab-workhorse/` |
| 包内 Shell | `gitlab_pkg/gitlab-shell/` |
| 服务器打包命令 | `cd /home/git && tar -cJf /tmp/gitlab_pkg.tar.xz gitlab/ gitaly/ gitlab-shell/ gitlab-workhorse/ gitlab-pages/` |

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
├── start_gitlab.sh               # 预编译包快速部署启动（跳过编译）
├── gitlab_pkg/                   # 预编译产物目录
│   └── README.md                 # 目录说明 + 生成方式
├── filelist.txt
├── build/
│   ├── build_gitlab.sh           # Omnibus + Docker 准备
│   ├── build_gitlab_source.sh    # 源码构建（CentOS 9）
│   ├── install_gitlab.sh         # Omnibus + Docker 安装
│   ├── install_gitlab_source.sh  # 源码构建安装（含 Nginx 自动配置）
│   ├── clean_gitlab.sh           # 卸载清理（含 Nginx 清理）
│   ├── pack_gitlab_sources.sh    # 离线源码包打包
│   ├── Dockerfile                # Docker 定制模板
│   └── gitlab.rb.template        # Omnibus 配置模板
├── manifests/                    # K8s 部署清单（预留）
├── workflow/                     # Python 工作流（预留）
└── verify/                       # 健康校验（预留）
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
| `source` | systemd 服务 + /home/git/* + /usr/local/ruby + /usr/local/go + Node 二进制 + **Nginx（仅 GitLab 反代配置 / 无其他站点时完全卸载）** |
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
> **安装脚本已自动处理（v3 自适应公式）：**  
> - 编译前自动 stop Puma / Sidekiq / Workhorse 释放内存  
> - 虚拟内存 < 16 GB 时**自动创建/扩容 swap** 到 16 GB  
> - **自适应 Node 堆**：单 worker 80% 虚拟内存 / 多 worker 70%，每进程 4096-5120 MB  
> - **自动降级**：堆 < 4096 时自动减少 worker 数直到满足  
> - 通过 `--require` 注入 monkey-patch 限制 `os.cpus()` 控制 terser 并行度  
> - 支持手动覆盖：`NODE_HEAP_MB=4096 WEBPACK_PARALLEL=1 bash install_gitlab_source.sh`  
>
> | 机器配置 | 虚拟内存 | Worker 数 | 堆/进程 | 能否编译 |
> |----------|---------|----------|---------|---------|
> | 16 GB + 0 swap → 脚本扩至 16 GB | 16 GB | 1 | 5120 MB | ✅ |
> | 12 GB + 0 swap → 脚本扩至 16 GB | 16 GB | 1 | 5120 MB | ✅ |
> | 9 GB + 7 GB swap（脚本自动创建） | 16 GB | 1 | 5120 MB | ✅ 实测通过 |
> | 9 GB + 0 swap → 脚本扩至 16 GB | 16 GB | 1 | 5120 MB | ✅ |
> | < 8 GB + 0 swap | < 14 GB | 1 | 4096 MB | ⚠️ 极慢但可能成功 |
>
> **编译失败诊断：**  
> 脚本会自动区分四类错误：
> - **CRLF 残留** → 自动清理后重试  
> - **V8 堆溢出** (`heap out of memory` / `SIGABRT`) → 减小 worker 或增大 swap  
> - **系统 OOM Kill** (`SIGKILL`) → 虚拟内存不足，增加 swap  
> - **Worker 崩溃** (`EPIPE`) → worker-farm 子进程内存不足，自动降 worker 重试  
>
> **已知问题：CRLF 换行符**  
> 源码包在 Windows 解压后可能残留 `\r` 换行符，导致 `Permission denied`。  
> 安装脚本启动时自动检测并清理 `scripts/` `bin/` `config/` 目录下的 CRLF 文件。
