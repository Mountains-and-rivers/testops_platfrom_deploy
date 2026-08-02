# Nginx 1.26.2 — 单机部署

> **当前模式：裸机二进制启动**（官方预编译 RPM → rpm2cpio 提取 → 手动部署）

### 部署模式矩阵

| 模式 | 构建方式 | 启动方式 | 状态 |
|------|----------|----------|------|
| **裸机二进制启动** | 官方预编译 RPM（rpm2cpio 提取） | 裸机 systemd | ✅ 已实现 |
| 裸机源码启动 | `./configure → make → make install` | 裸机 systemd | 🚧 TODO |
| 源码构建 Docker 启动 | `./configure → make → make install` → docker build | Docker 容器 | 🚧 TODO |
| 二进制构建 Docker 启动 | 官方 RPM → docker build | Docker 容器 | 🚧 TODO |

> 后三种模式已在 `install_nginx.sh` 中预留入口（`--source` / `--docker` 参数），暂不实现。

---

## 一键执行

```bash
# 基础安装（二进制 RPM，本地包优先，默认监听 80 端口）
bash install_nginx.sh

# 指定端口
bash install_nginx.sh --port 8080

# 指定安装路径
bash install_nginx.sh --prefix /opt/nginx

# 卸载（保留 /etc/nginx 配置）
bash uninstall_nginx.sh

# 卸载（含配置 + nginx 用户 + 日志）
bash uninstall_nginx.sh --data
```

---

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--port` | HTTP 监听端口 | 80 |
| `--prefix` | Nginx 安装目录 | /usr/local/nginx |
| 环境变量 `NGINX_PORT` | 同 --port | 80 |
| 环境变量 `NGINX_USER` | 运行用户 | nginx |
| 环境变量 `LOG_DIR` | 日志目录 | /var/log/nginx |
| 环境变量 `CACHE_DIR` | 缓存目录 | /var/cache/nginx |
| 环境变量 `RUN_DIR` | PID/运行时目录 | /var/run |

---

## 版本信息

| 项目 | 值 |
|------|-----|
| Nginx | **1.26.2**（最新 stable） |
| 二进制包 | `nginx-1.26.2-1.el9.ngx.x86_64.rpm` |
| 来源 | nginx.org 官方预编译 |
| 下载地址 | https://nginx.org/packages/centos/9/x86_64/RPMS/ |
| 安装方式 | `rpm2cpio` 提取 → 手动部署到 `/usr/local/nginx/`（不注册到 RPM 数据库） |

> **下载命令（在可联网机器上）：**
> ```bash
> wget https://nginx.org/packages/centos/9/x86_64/RPMS/nginx-1.26.2-1.el9.ngx.x86_64.rpm
> ```
> 将下载的 `.rpm` 文件放到脚本同目录即可离线安装。

---

## 安装流程

```
[0/5]   已安装检测   → 版本存在则跳过（幂等）
[1/5]   获取 RPM     → 脚本目录 → /tmp/build-cache/ → 在线下载
                       rpm2cpio 提取 → 部署到 /usr/local/nginx/
[2/5]   配置         → nginx.conf（本地模板优先 → 生成默认配置）
[3/5]   systemd      → nginx.service（enable 开机自启 + start）
[4/5]   功能验证     → 进程 + 端口 + HTTP 响应 + 防火墙
[5/5]   完成         → 版本信息 + 目录 + 管理命令
```

### 已安装检测逻辑

```
Nginx 二进制存在 (/usr/local/nginx/sbin/nginx) → 跳过安装
                                             → 确保 systemd 服务运行
```

---

## 目录结构

```
nginx/
├── .gitignore
├── README.md
├── install_nginx.sh              # 安装脚本（rpm2cpio 提取方式）
└── uninstall_nginx.sh            # 卸载清理脚本
```

安装后的目录结构：

```
/usr/local/nginx/
├── sbin/
│   └── nginx                     # 二进制（软链 → /usr/sbin/nginx）
├── conf/
│   ├── nginx.conf                # 主配置
│   ├── mime.types                # MIME 类型映射
│   ├── nginx.conf.rpmorig        # RPM 原始配置（备用）
│   └── conf.d/                   # 子配置目录 → include *.conf
│       └── gitlab.conf           # GitLab 反代配置（自动生成）
├── share/nginx/html/             # 默认 HTML 根目录
└── ...
```

---

## 默认配置

| 配置项 | 值 |
|--------|-----|
| 安装路径 | `/usr/local/nginx` |
| 监听端口 | 80 |
| 运行用户 | `nginx` |
| worker_processes | `auto`（自动匹配 CPU 核数） |
| worker_connections | 1024 |
| I/O 模型 | `epoll` |
| sendfile | `on` |
| tcp_nopush / tcp_nodelay | `on` |
| keepalive_timeout | 65s |
| client_max_body_size | 250m |
| gzip | `on`（text/css/js/json/xml） |
| 访问日志 | `/var/log/nginx/access.log` |
| 错误日志 | `/var/log/nginx/error.log`（warn 级别） |
| PID 文件 | `/var/run/nginx.pid` |
| 开机自启 | `systemctl enable nginx` |

---

## 自定义配置模板

安装脚本支持从同目录读取自定义 `nginx.conf` 模板，替换变量：

| 模板变量 | 说明 |
|----------|------|
| `{{NGINX_USER}}` | 运行用户 |
| `{{NGINX_PORT}}` | 监听端口 |
| `{{LOG_DIR}}` | 日志目录 |
| `{{CACHE_DIR}}` | 缓存目录 |
| `{{RUN_DIR}}` | PID 目录 |

用法：将自定义 `nginx.conf` 放到脚本同目录，脚本自动检测并使用。

---

## 系统要求

| 资源 | 最低 |
|------|------|
| CPU | 1 Core |
| 内存 | 512 MB |
| 磁盘 | 1 GB |

---

## 管理命令

```bash
systemctl start nginx              # 启动
systemctl stop nginx               # 停止
systemctl restart nginx            # 重启
systemctl reload nginx             # 热重载配置
systemctl status nginx             # 查看状态
systemctl is-enabled nginx         # 是否开机自启
journalctl -u nginx -f             # 实时日志

nginx -t                           # 配置语法检查
nginx -s reload                    # 热重载（等效 systemctl reload）
nginx -v                           # 版本号
nginx -V                           # 版本号 + 编译参数
```

---

## 反向代理架构（GitLab 集成）

脚本安装后仅提供默认静态页面。GitLab 集成时，由 `install_gitlab_source.sh` 调用本脚本自动安装 Nginx，并生成反代配置：

```
Client (:80/443)
  │
  ▼
Nginx (:80)
  ├── /assets/*   → 静态文件直出 (gzip_static, expires max)
  ├── /uploads/*  → 静态文件直出
  ├── /*.git/*    → Workhorse (:8181) — Git HTTP 流量
  └── /*           → Workhorse (:8181) — 鉴权 + 转发
                        │
                        ▼
                    Puma (:3000) — Rails Web 请求
```

### GitLab 反代配置要点

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `upstream gitlab-workhorse` | `127.0.0.1:8181` | Workhorse 处理 git-over-HTTP |
| `upstream gitlab-puma` | `127.0.0.1:3000` | Puma 处理 Rails Web 请求 |
| `client_max_body_size` | 250m | Git push 大文件 |
| `proxy_read_timeout` | 3600s | 长时间 Git 操作 |
| 静态资源 | gzip_static + expires max | 前端编译产物缓存 |

---

## 远程连接与防火墙

安装后自动放行 `http`/`https` 服务：

```bash
firewall-cmd --add-service=http --permanent
firewall-cmd --add-service=https --permanent
firewall-cmd --reload
```

如需限制来源 IP（推荐生产环境）：

```bash
firewall-cmd --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="80" protocol="tcp" accept' --permanent
firewall-cmd --reload
```

---

## 卸载

```bash
bash uninstall_nginx.sh            # 保留 /etc/nginx
bash uninstall_nginx.sh --data     # 全部清理（含配置 + 用户 + 日志 + 缓存）
```

卸载流程：

```
[1/4]   停止服务    → systemctl stop + disable + 删除 systemd 单元
[2/4]   移除安装    → 清理 /usr/local/nginx/ + RPM 残留
[3/4]   删除用户    → userdel nginx
[4/4]   日志 + 配置 → /var/log/nginx /var/cache/nginx（--data 含 /etc/nginx）
```

---

## GitLab 源码安装中的 Nginx 清理

`clean_gitlab.sh source` 卸载 GitLab 时会同步处理 Nginx：

| 情况 | 行为 |
|------|------|
| Nginx 仅用于 GitLab（无其他站点配置） | 完全卸载 Nginx |
| Nginx 有其他站点配置 | 仅删除 `gitlab.conf` + reload，保留 Nginx |
| 指定 `--data` | 强制完全卸载 Nginx（调用 `uninstall_nginx.sh --data`） |

---

## TODO

- [ ] **裸机源码启动**：`nginx-1.26.2.tar.gz → ./configure → make → make install`（`install_nginx.sh --source`）
  - `./configure --prefix=/usr/local/nginx --user=nginx --group=nginx`
  - `--with-http_ssl_module --with-http_v2_module --with-http_realip_module`
  - `--with-stream --with-stream_ssl_module`
- [ ] **源码构建 Docker 启动**：源码编译产物 → Dockerfile → 镜像 → 容器（`install_nginx.sh --source --docker`）
- [ ] **二进制构建 Docker 启动**：官方 RPM 提取 → Dockerfile → 镜像 → 容器（`install_nginx.sh --docker`）
- [ ] HTTPS / SSL 证书自动配置（Let's Encrypt / acme.sh）
- [ ] 负载均衡 upstream 多节点模板
