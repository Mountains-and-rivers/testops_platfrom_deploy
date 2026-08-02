# gitlab_pkg — GitLab 预编译产物

将编译好的 GitLab 文件放入此目录，由 `start_gitlab.sh` 一键部署启动。**支持自动解压 `gitlab_pkg.tar.xz`**。

---

## 快速开始

```bash
# 1. 确保 PostgreSQL 18+ 和 Redis 7+ 已安装运行
bash ../postgresql18/install_postgresql.sh --for-gitlab
bash ../redis7/install_redis.sh

# 2. 一键启动（自动解压 gitlab_pkg.tar.xz → 部署 → 配置 → 启动）
bash start_gitlab.sh 192.168.10.6

# 3. 访问
# http://192.168.10.6
# 账号: root  密码: Gitlab12345
```

> **`start_gitlab.sh` 自动检测逻辑：**  
> - `gitlab_pkg.tar.xz` 存在 + 未解压 → **自动解压**到当前目录  
> - 已解压（`gitlab/` `gitaly/` 等目录存在） → **跳过解压**  
> - 都无 → **报错退出**

---

## 目录结构

```
gitlab_pkg/
├── README.md                          ← 本文件
├── gitlab_pkg.tar.xz                  ← 预编译压缩包
├── gitlab/                            ← GitLab 源码 + 全部依赖
│   ├── start_gitlab.sh                ← 【服务启动脚本】部署后在此运行
│   ├── app/                           # Rails 应用
│   ├── config/                        # 配置文件
│   ├── public/assets/                 # 预编译的前端资源（webpack 产物）
│   ├── vendor/bundle/                 # Ruby Gems（bundle install --deployment）
│   ├── node_modules/                  # Node.js 依赖
│   └── tmp/.webpack_compile_done      # 编译完成标记（跳过重复编译）
├── gitaly/                            ← Gitaly Git RPC 服务（Go 编译产物）
│   └── _build/bin/gitaly
├── gitlab-shell/                      ← GitLab Shell SSH 接口（Go 编译产物）
│   └── bin/gitlab-shell
├── gitlab-workhorse/                  ← Workhorse 反向代理（Go 编译产物）
│   └── gitlab-workhorse
└── gitlab-pages/                      ← Pages 静态站点服务（可选）
    └── gitlab-pages
```

### 各组件说明

| 组件 | 语言 | 职责 | 对外端口 |
|------|------|------|---------|
| **gitlab** (Rails) | Ruby | Web UI / API / 业务逻辑 | Puma :3000 |
| **gitaly** | Go | Git 仓库 RPC 操作（clone/push/commit） | gRPC unix socket |
| **gitlab-shell** | Go | SSH git 操作（`git@host:repo.git`） | — |
| **gitlab-workhorse** | Go | HTTP 反代 / Git over HTTP / 鉴权 / LFS | unix socket |
| **gitlab-pages** | Go | 静态站点托管（可选） | — |

---

## 生成预编译包

在一台 **16GB+ RAM** 的编译机上执行：

```bash
# 完整编译
bash build/build_gitlab_source.sh 19-3-stable
bash build/install_gitlab_source.sh gitlab.testops.local

# 打包编译产物
cd /home/git
tar -cJf /tmp/gitlab_pkg.tar.xz \
    gitlab/ \
    gitaly/ \
    gitlab-shell/ \
    gitlab-workhorse/ \
    gitlab-pages/

# 下载到本地 gitlab_pkg/ 目录
scp root@<编译机IP>:/tmp/gitlab_pkg.tar.xz ./gitlab_pkg/
```

---

## PostgreSQL 连接配置

### 默认配置（本地 PostgreSQL）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `PG_HOST` | `127.0.0.1` | PostgreSQL 地址 |
| `PG_PORT` | `5432` | PostgreSQL 端口 |
| `PG_USER` | `postgres` | 管理员用户 |
| `PG_PASSWORD` | `Pg1@zendao2024` | 管理员密码 |
| git 用户密码 | `Pg1@zendao2024` | GitLab 数据库用户 |

### 自定义配置

```bash
# 方式 1：环境变量
PG_HOST=192.168.10.5 PG_PORT=5432 PG_PASSWORD=MyPass123 bash start_gitlab.sh 192.168.10.6

# 方式 2：编辑 remote 配置文件
vim build/gitlab_remote.conf
```

`build/gitlab_remote.conf` 内容：

```bash
REMOTE=true
PG_HOST=192.168.10.5
PG_PORT=5432
PG_USER=postgres
PG_PASSWORD=MyPass123
REDIS_HOST=192.168.10.5
REDIS_PORT=6379
REDIS_PASSWORD=MyPass123
```

### 首次安装 PostgreSQL（推荐）

```bash
# 本地安装 PG 18 + 自动创建 GitLab 所需扩展和用户
bash ../postgresql18/install_postgresql.sh --for-gitlab
```

`--for-gitlab` 会自动：
- 安装 `postgresql18-contrib`（`pg_trgm`、`btree_gist` 扩展）
- 创建 `git` 数据库用户
- 创建 `gitlabhq_production` 数据库

---

## Redis 连接配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `REDIS_HOST` | `127.0.0.1` | Redis 地址 |
| `REDIS_PORT` | `6379` | Redis 端口 |
| `REDIS_PASSWORD` | `Pg1@zendao2024` | Redis 密码 |

GitLab 使用 Redis 的三个场景：

| 用途 | 配置文件 |
|------|---------|
| Sidekiq 后台任务队列 | `/home/git/gitlab/config/resque.yml` |
| ActionCable 实时通知 | `/home/git/gitlab/config/cable.yml` |
| Workhorse 缓存/限流 | 启动参数自动连接 |

---

## 安装完成后访问

| 地址 | 说明 |
|------|------|
| `http://<IP>` | GitLab Web UI（通过 Nginx :80） |
| `http://<IP>:3000` | ⚠️ 不要用！生产模式 Puma 不提供静态文件 |

首次访问流程：
1. 打开 `http://192.168.10.6`
2. 跳转到 `/users/sign_in` 登录页
3. 如果 root 密码未设置 → `/admin/initial_setup/new` 设置密码
4. 用户名 `root`，密码 `Gitlab12345`

### 常用页面

| 页面 | 路径 |
|------|------|
| 项目列表 | `/dashboard/projects` |
| 创建项目 | `/projects/new` |
| 用户设置 | `/-/profile` |
| Admin 面板 | `/admin` |
| 健康检查 | `/help` |

---

## 部署后启动（gitlab 目录内脚本）

解压部署到 `/home/git/` 后，可以直接从 gitlab 目录内启动：

```bash
cd /home/git/gitlab
bash start_gitlab.sh
```

| 参数 | 说明 |
|------|------|
| `--port 8080` | 自定义 HTTP 端口 |
| `--skip-nginx` | 跳过 Nginx，仅启动后端服务 |

该脚本自动：
1. 检测自身所在目录作为 `GITLAB_DIR`
2. 按顺序启动：**Gitaly → Puma + Sidekiq → Workhorse**
3. 生成/修正 Nginx 反代配置并启动
4. 修正权限（nginx→git 组、目录遍历）
5. 等待 GitLab 就绪（最多 45s）

### 两个 start_gitlab.sh 的区别

| 位置 | 用途 |
|------|------|
| `pkg_deploy/gitlab/start_gitlab.sh` | **完整部署**：解包 → 配置 → 启动（用于首次部署） |
| `gitlab_pkg/gitlab/start_gitlab.sh` | **纯启动**：假设已部署，直接启服务（用于日常启停） |

---

## 服务管理

### 一键状态检查

```bash
for s in postgresql redis gitlab-gitaly gitlab-puma gitlab-sidekiq gitlab-workhorse nginx; do
    echo -n "$s: "; systemctl is-active $s 2>/dev/null || echo "not-found"
done
```

### 启动 / 停止 / 重启

```bash
systemctl start gitlab.target     # 启动全部
systemctl stop gitlab.target      # 停止全部
systemctl restart gitlab-puma     # 重启单个组件

# 启动顺序（手动时需遵守）
systemctl start gitlab-gitaly
systemctl start gitlab-puma gitlab-sidekiq
systemctl start gitlab-workhorse
systemctl start nginx
```

### 日志查看

```bash
journalctl -u gitlab-puma -f         # Puma 实时日志
journalctl -u gitlab-workhorse -f    # Workhorse 实时日志
journalctl -u gitlab-sidekiq -f      # Sidekiq 实时日志
journalctl -u gitlab-gitaly -f       # Gitaly 实时日志
tail -f /home/git/gitlab/log/production_json.log  # Rails 生产日志
tail -f /var/log/nginx/gitlab_error.log          # Nginx 错误日志
```

---

## Git 仓库操作

### HTTP 方式（推荐内网）

```bash
# Clone
git clone http://192.168.10.6/root/myapp.git

# Push
cd myapp
echo "# My App" > README.md
git add . && git commit -m "init"
git push -u origin main

# 认证: 用户名 root，密码 Gitlab12345
```

### SSH 方式

```bash
# 1. 在 GitLab Web UI 中添加 SSH Key（/-/profile/keys）
# 2. Clone
git clone git@192.168.10.6:root/myapp.git
```

> SSH Clone 失败常见原因：
> - SSH Key 未添加到 GitLab
> - gitlab-shell 未正确配置
> - SSH 端口非 22（检查 `/home/git/.ssh/authorized_keys` 和 gitlab-shell `/home/git/gitlab-shell/config.yml`）

---

## 卸载

```bash
# 保留数据
bash build/clean_gitlab.sh source

# 全部清理（含数据库 + git 用户 + Nginx）
bash build/clean_gitlab.sh source --data
```
