# PostgreSQL 18.4 — 单机部署

> 二进制 RPM（PGDG）安装 / 源码编译（TODO）

---

## 一键执行

```bash
# 基础安装（本地 RPM 优先，默认开启远程连接）
bash install_postgresql.sh

# 指定端口、密码和绑定地址
bash install_postgresql.sh --port 5432 --password MyPass123 --bind '*'

# 仅监听本地（禁止远程连接）
bash install_postgresql.sh --bind 127.0.0.1

# GitLab 专用安装（自动安装 contrib + 创建 git 用户和 gitlabhq_production 库）
bash install_postgresql.sh --for-gitlab

# GitLab 专用 + 自定义参数
bash install_postgresql.sh --for-gitlab --port 5432 --password GitlabPwd123 --bind '*'

# 卸载（保留 /data/postgresql）
bash uninstall_postgresql.sh

# 卸载（含数据 + 用户）
bash uninstall_postgresql.sh --data
```

---

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--port` | 监听端口 | 5432 |
| `--password` | postgres 用户密码（GitLab 模式同时用于 git 用户） | Pg1@zendao2024 |
| `--bind` | 监听地址（`*`=所有网卡，`0.0.0.0`=所有 IPv4） | * |
| `--for-gitlab` | **GitLab 专用模式**，详见下方说明 | 关闭 |
| 环境变量 `PG_PORT` | 同 --port | 5432 |
| 环境变量 `PG_BIND` | 同 --bind | * |
| 环境变量 `DATA_DIR` | 数据目录 | /data/postgresql |
| 环境变量 `LOG_DIR` | 日志目录 | /var/log/postgresql |

### `--for-gitlab` 参数详解

指定此参数后，脚本会额外执行以下操作：

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1.5 | 安装 `postgresql18-contrib` RPM 包 | 提供 `btree_gist`、`pg_trgm` 等扩展 |
| 4.5 | 创建扩展 `pg_trgm`、`btree_gist`、`plpgsql` | GitLab schema 运行所需 |
| 4.5 | 创建 git 用户（密码同 postgres） | `CREATE USER git CREATEDB` |
| 4.5 | 创建 `gitlabhq_production` 数据库（owner: git） | GitLab 生产数据库 |

**关键行为区别：**

- **不加 `--for-gitlab`**：PG 已安装时直接退出跳过（幂等）
- **加 `--for-gitlab`**：PG 已安装时不会退出，继续检查 contrib 包和 GitLab 初始化是否到位，确保幂等安全

contrib 包同样遵循**本地优先**策略（脚本同目录 → `/tmp/build-cache/` → 在线 dnf）。

---

## 版本信息

| 项目 | 值 |
|------|-----|
| PostgreSQL | **18.4** |
| 二进制包 | PGDG 官方 RPM × 4（含 contrib） |
| 下载地址 | https://download.postgresql.org/pub/repos/yum/18/redhat/rhel-9-x86_64/ |

### 离线包清单

| 文件 | 大小 | 用途 |
|------|------|------|
| `postgresql18-libs-18.4-2PGDG.rhel9.8.x86_64.rpm` | ~300K | 基础库（必装） |
| `postgresql18-18.4-2PGDG.rhel9.8.x86_64.rpm` | ~2.0M | 客户端（必装） |
| `postgresql18-server-18.4-2PGDG.rhel9.8.x86_64.rpm` | ~7.5M | 服务端（必装） |
| `postgresql18-contrib-18.4-2PGDG.rhel9.8.x86_64.rpm` | ~800K | 扩展包（GitLab 模式需要） |

> **下载命令（在可联网机器上）：**
> ```bash
> dnf download postgresql18 postgresql18-libs postgresql18-server postgresql18-contrib
> ```
> 将下载的 4 个 `.rpm` 文件放到脚本同目录即可离线安装。

---

## 安装流程

```
[0/6]   已安装检测   → 版本一致且非 GitLab 模式则跳过
[1/6]   安装 RPM     → 本地 3 个 rpm → dnf 在线
[1.5/6] contrib      → （仅 --for-gitlab）本地优先 → dnf 在线
[2/6]   初始化       → initdb + postgresql.conf + pg_hba.conf
[3/6]   systemd      → enable（开机自启）+ start
[4/6]   设置密码     → ALTER USER postgres PASSWORD
[4.5/6] GitLab 初始化 → （仅 --for-gitlab）扩展 + git 用户 + gitlabhq_production 库
[5/6]   功能验证     → 进程 + 端口 + socket 连接 + TCP 密码连接
[6/6]   完成         → 进程状态 + 账号信息 + 连接命令
```

### 安装完成输出示例（GitLab 模式）

```
============================================
  PostgreSQL 18.4 安装完成
  用途: GitLab 数据库

  ── 账号信息 ──
  用户名: postgres
  密码:   Pg1@zendao2024
  数据库: zendao
  绑定地址: * (远程连接已开启)

  ── GitLab 数据库 ──
  git 用户: git / Pg1@zendao2024
  数据库:   gitlabhq_production (owner: git)
  扩展:     pg_trgm, btree_gist, plpgsql

  ── 连接命令 ──
  # GitLab 数据库连接
  PGPASSWORD='Pg1@zendao2024' psql -U git -h <服务器IP> -p 5432 -d gitlabhq_production
============================================
```

---

## 目录结构

```
postgresql18/
├── .gitignore
├── README.md
├── install_postgresql.sh                             # 安装脚本
├── uninstall_postgresql.sh                           # 清理脚本
├── postgresql18-libs-18.4-2PGDG.rhel9.8.x86_64.rpm   # 本地离线包
├── postgresql18-18.4-2PGDG.rhel9.8.x86_64.rpm
├── postgresql18-server-18.4-2PGDG.rhel9.8.x86_64.rpm
└── postgresql18-contrib-18.4-2PGDG.rhel9.8.x86_64.rpm  # GitLab 扩展包
```

---

## 默认配置

| 配置项 | 值 |
|--------|-----|
| 安装路径 | `/usr/pgsql-18` |
| 监听地址 | `*`（所有网卡，远程连接已开启） |
| 最大连接 | 200 |
| shared_buffers | 256MB |
| 远程认证 | `md5`（0.0.0.0/0，密码认证） |
| 编码 | UTF8 |
| 开机自启 | `systemctl enable postgresql` |
| 默认数据库 | `zendao` |
| postgres 密码 | `Pg1@zendao2024` |

---

## 系统要求

| 资源 | 最低 |
|------|------|
| CPU | 1 Core |
| 内存 | 1 GB |
| 磁盘 | 5 GB |

---

## 管理命令

```bash
systemctl start postgresql        # 启动
systemctl stop postgresql         # 停止
systemctl restart postgresql      # 重启
systemctl status postgresql       # 状态
systemctl is-enabled postgresql   # 是否开机自启
journalctl -u postgresql -f       # 日志

# 连接 — 三种方式
sudo -u postgres psql                                            # 本地 socket（免密）
psql -U postgres -h 127.0.0.1 -p 5432                            # TCP 密码连接
PGPASSWORD='Pg1@zendao2024' psql -U postgres -h 127.0.0.1 -p 5432  # 环境变量
```

## 远程连接

安装完成后 PostgreSQL 默认已开启远程连接（`listen_addresses = '*'` + `pg_hba.conf` 允许 `0.0.0.0/0 md5`），可从其他机器连接：

```bash
# 从远程机器连接（替换 <服务器IP> 为实际地址）
psql -U postgres -h <服务器IP> -p 5432
# 输入密码: Pg1@zendao2024

# 环境变量方式（密码不显示在命令行）
PGPASSWORD='Pg1@zendao2024' psql -U postgres -h <服务器IP> -p 5432

# 测试远程连通性
PGPASSWORD='Pg1@zendao2024' psql -U postgres -h <服务器IP> -p 5432 -c 'SELECT version();'
```

**安全建议**:
- 生产环境请修改默认密码（`--password` 参数）
- 如只需本地访问，使用 `--bind 127.0.0.1` 关闭远程连接
- 建议配合防火墙白名单限制来源 IP：
  ```bash
  firewall-cmd --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="5432" protocol="tcp" accept' --permanent
  firewall-cmd --reload
  ```

---

## GitLab 集成使用

### 场景一：PG 和 GitLab 同机部署

```bash
# 一键完成 PG 安装 + GitLab 初始化
bash install_postgresql.sh --for-gitlab
```

### 场景二：PG 独立部署，GitLab 远程连接

```bash
# Step 1: 在 PG 服务器上执行
bash install_postgresql.sh --for-gitlab --bind '*'

# Step 2: 在 GitLab 服务器执行安装脚本时指定远程 PG 参数
# （由 install_gitlab_source.sh 的 --pg-host 等参数控制）
```

### GitLab 所需的手动 SQL（参考）

```sql
-- install_postgresql.sh --for-gitlab 已自动执行以下操作：
CREATE USER git CREATEDB;
ALTER USER git WITH PASSWORD 'Pg1@zendao2024';
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS plpgsql;
CREATE DATABASE gitlabhq_production OWNER git;
```

---

## 卸载

```bash
bash uninstall_postgresql.sh         # 保留 /data/postgresql
bash uninstall_postgresql.sh --data  # 全部清理（含数据 + RPM + 用户）
```

---

## TODO

- [ ] 源码编译模式：`postgresql.4.tar.gz → ./configure → make → make install`
- [ ] 集群模式：Patroni + etcd 高可用
