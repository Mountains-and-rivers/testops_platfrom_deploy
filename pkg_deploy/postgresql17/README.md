# PostgreSQL 16.8 — 单机部署

> 二进制 RPM（PGDG）安装 / 源码编译（TODO）

---

## 一键执行

```bash
# 安装（本地 RPM 优先）
bash install_postgresql.sh

# 指定端口和密码
bash install_postgresql.sh --port 5432 --password MyPass123

# 卸载（保留 /data/postgresql）
bash uninstall_postgresql.sh

# 卸载（含数据 + 用户）
bash uninstall_postgresql.sh --data
```

---

## 版本信息

| 项目 | 值 |
|------|-----|
| PostgreSQL | **16.8** |
| 二进制包 | PGDG 官方 RPM × 3 |
| 下载地址 | https://download.postgresql.org/pub/repos/yum/16/redhat/rhel-9-x86_64/ |

### 离线包清单

| 文件 | 大小 |
|------|------|
| `postgresql17-libs-16.8-1PGDG.rhel9.x86_64.rpm` | ~335K |
| `postgresql17-16.8-1PGDG.rhel9.x86_64.rpm` | ~1.8M |
| `postgresql17-server-16.8-1PGDG.rhel9.x86_64.rpm` | ~6.8M |

---

## 安装流程

```
[0/6] 已安装检测  →  版本一致则跳过
[1/6] 安装 RPM    →  本地 3 个 rpm → dnf 在线
[2/6] 初始化      →  initdb + postgresql.conf + pg_hba.conf
[3/6] systemd     →  enable（开机自启）+ start
[4/6] 设置密码    →  ALTER USER postgres PASSWORD
[5/6] 功能验证    →  进程 + 端口 + socket 连接 + TCP 密码连接
[6/6] 完成        →  进程状态 + 账号信息 + 连接命令
```

### 安装完成输出示例

```
--- 服务状态 ---
● postgresql-16.service - PostgreSQL 16.8
   Active: active (running)

============================================
  PostgreSQL 16.8 安装完成

  ── 账号信息 ──
  用户名: postgres
  密码:   Pg1@zendao2024
  数据库: zendao

  ── 连接命令 ──
  # 本地 socket 连接（免密）
  sudo -u postgres psql

  # TCP 密码连接
  psql -U postgres -h 127.0.0.1 -p 5432

  # 环境变量方式
  PGPASSWORD='Pg1@zendao2024' psql -U postgres -h 127.0.0.1 -p 5432

  ── 管理命令 ──
  systemctl status postgresql-16
  systemctl {start|stop|restart|reload} postgresql-16
============================================
```

---

## 目录结构

```
postgresql17/
├── .gitignore
├── README.md
├── install_postgresql.sh                          # 安装脚本
├── uninstall_postgresql.sh                        # 清理脚本
├── postgresql17-libs-16.8-1PGDG.rhel9.x86_64.rpm  # 本地离线包
├── postgresql17-16.8-1PGDG.rhel9.x86_64.rpm
└── postgresql17-server-16.8-1PGDG.rhel9.x86_64.rpm
```

---

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--port` | 监听端口 | 5432 |
| `--password` | postgres 用户密码 | Pg1@zendao2024 |
| 环境变量 `PG_PORT` | 同 --port | 5432 |
| 环境变量 `DATA_DIR` | 数据目录 | /data/postgresql |
| 环境变量 `LOG_DIR` | 日志目录 | /var/log/postgresql |

---

## 默认配置

| 配置项 | 值 |
|--------|-----|
| 安装路径 | `/usr/pgsql-16` |
| 监听地址 | `*`（所有网卡） |
| 最大连接 | 200 |
| shared_buffers | 256MB |
| 远程认证 | `md5`（0.0.0.0/0） |
| 编码 | UTF8 |
| 开机自启 | `systemctl enable postgresql-16` |
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
systemctl start postgresql-16        # 启动
systemctl stop postgresql-16         # 停止
systemctl restart postgresql-16      # 重启
systemctl status postgresql-16       # 状态
systemctl is-enabled postgresql-16   # 是否开机自启
journalctl -u postgresql-16 -f       # 日志

# 连接 — 三种方式
sudo -u postgres psql                                            # 本地 socket（免密）
psql -U postgres -h 127.0.0.1 -p 5432                            # TCP 密码连接
PGPASSWORD='Pg1@zendao2024' psql -U postgres -h 127.0.0.1 -p 5432  # 环境变量
```

## 卸载

```bash
bash uninstall_postgresql.sh         # 保留 /data/postgresql
bash uninstall_postgresql.sh --data  # 全部清理（含数据 + RPM + 用户）
```

---

## 给 GitLab 使用的数据库初始化命令

```sql
CREATE USER git CREATEDB;
ALTER USER git WITH PASSWORD 'Pg1@zendao2024';
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS plpgsql;
CREATE DATABASE gitlabhq_production OWNER git;
```

---

## TODO

- [ ] 源码编译模式：`postgresql-16.8.tar.gz → ./configure → make → make install`
- [ ] 集群模式：Patroni + etcd 高可用
