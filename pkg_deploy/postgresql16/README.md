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
| `postgresql16-libs-16.8-1PGDG.rhel9.x86_64.rpm` | ~335K |
| `postgresql16-16.8-1PGDG.rhel9.x86_64.rpm` | ~1.8M |
| `postgresql16-server-16.8-1PGDG.rhel9.x86_64.rpm` | ~6.8M |

---

## 安装流程

```
[0/6] 已安装检测  →  版本一致则跳过
[1/6] 获取 RPM    →  本地目录（3 个 rpm 缺一不可）→ dnf 在线
[2/6] 安装 RPM    →  rpm -ivh / dnf localinstall
[3/6] 初始化      →  initdb + postgresql.conf + pg_hba.conf
[4/6] systemd     →  enable（开机自启）+ start
[5/6] 功能验证    →  进程 + 端口 + 密码 + 连接测试
[6/6] 完成
```

---

## 目录结构

```
postgresql16/
├── .gitignore
├── README.md
├── install_postgresql.sh                          # 安装脚本
├── uninstall_postgresql.sh                        # 清理脚本
├── postgresql16-libs-16.8-1PGDG.rhel9.x86_64.rpm  # 本地离线包
├── postgresql16-16.8-1PGDG.rhel9.x86_64.rpm
└── postgresql16-server-16.8-1PGDG.rhel9.x86_64.rpm
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

# 连接
psql -U postgres -h 127.0.0.1 -p 5432
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
