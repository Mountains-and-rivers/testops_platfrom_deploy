# PostgreSQL 16.8 — 单机部署

> 二进制 tar.gz 安装（源码编译 TODO）

---

## 一键执行

```bash
# 安装（二进制 tar.gz，本地包优先）
bash install_postgresql.sh

# 指定端口和密码
bash install_postgresql.sh --port 5432 --password MyPass123

# 卸载（保留 /data/postgresql）
bash uninstall_postgresql.sh

# 卸载（含数据）
bash uninstall_postgresql.sh --data
```

---

## 版本信息

| 项目 | 值 |
|------|-----|
| PostgreSQL | **16.8**（最新 16.x） |
| 二进制包 | `postgresql-16.8-1-linux-x64-binaries.tar.gz` |
| 下载 | https://get.enterprisedb.com/postgresql/ |

---

## 安装流程

```
[0/6] 已安装检测  →  版本一致则跳过
[1/6] 获取 tar.gz  →  本地目录 → /tmp/build-cache/ → 下载
[2/6] 解压安装     →  tar -xzf → /usr/local/postgresql
[3/6] 初始化       →  initdb + postgresql.conf + pg_hba.conf
[4/6] systemd      →  enable + start
[5/6] 功能验证     →  进程 + 端口 + 连接 + SQL 查询
[6/6] 完成
```

---

## 目录结构

```
postgresql16/
├── .gitignore
├── README.md
├── install_postgresql.sh          # 二进制 tar.gz 安装
└── uninstall_postgresql.sh        # 卸载清理
```

---

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--port` | 监听端口 | 5432 |
| `--password` | postgres 用户密码 | Pg1@zendao2024 |
| 环境变量 `PG_PORT` | 同 --port | 5432 |
| 环境变量 `INSTALL_DIR` | 安装目录 | /usr/local/postgresql |
| 环境变量 `DATA_DIR` | 数据目录 | /data/postgresql |
| 环境变量 `LOG_DIR` | 日志目录 | /var/log/postgresql |

---

## 默认配置

| 配置项 | 值 |
|--------|-----|
| 监听地址 | `*`（所有网卡） |
| 最大连接 | 200 |
| shared_buffers | 256MB |
| 远程认证 | `md5`（0.0.0.0/0） |
| 编码 | UTF8 |
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
journalctl -u postgresql -f       # 日志

# 连接
psql -U postgres -h 127.0.0.1 -p 5432
```

## 卸载

```bash
bash uninstall_postgresql.sh         # 保留 /data/postgresql
bash uninstall_postgresql.sh --data  # 全部清理
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
