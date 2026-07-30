# Redis 7.4.1 — 单机部署

> 二进制 RPM / dnf 在线安装 / 源码编译（TODO）

---

## 一键执行

```bash
# 安装（本地 RPM 优先）
bash install_redis.sh

# 指定端口和密码
bash install_redis.sh --port 6379 --password MyPass123

# 卸载（保留 /data/redis）
bash uninstall_redis.sh

# 卸载（含数据 + 用户）
bash uninstall_redis.sh --data
```

---

## 版本信息

| 项目 | 值 |
|------|-----|
| Redis | **7.4.1** |
| 二进制包 | `redis-*.rpm`（本地通配匹配，不限定来源） |
| 在线安装 | `dnf install redis` / `dnf module install redis:7` |
| 兜底下载 | https://rpm.redis.io/（官方 RPM） |

---

## 安装流程

```
[0/6] 已安装检测  →  版本一致则跳过
[1/6] 安装 Redis  →  本地 *.rpm → dnf redis → dnf module redis:7 → rpm.redis.io
[2/6] 配置        →  redis.conf（AOF + RDB + 密码）
[3/6] systemd     →  enable（开机自启）+ start
[4/6] 设置密码    →  requirepass 验证
[5/6] 功能验证    →  进程 + 端口 + PING + SET/GET
[6/6] 完成        →  服务状态 + 认证信息 + 连接命令
```

### 安装完成输出示例

```
--- 服务状态 ---
● redis.service - Redis 7.4.1
   Active: active (running)

============================================
  Redis 7.4.1 安装完成

  ── 认证信息 ──
  Redis 为单密码认证（无用户名概念）
  密码:   Redis1@zendao2024
  端口:   6379

  ── 连接命令 ──
  # 本地连接（无密码时）
  redis-cli

  # TCP 密码连接
  redis-cli -h 127.0.0.1 -p 6379 -a 'Redis1@zendao2024'

  # 交互式（先连接再认证，密码不泄露在命令行）
  redis-cli -h 127.0.0.1 -p 6379
  > AUTH Redis1@zendao2024

  ── 管理命令 ──
  systemctl status redis          # 查看状态
  systemctl {start|stop|restart} redis
============================================
```

---

## 目录结构

```
redis7/
├── .gitignore
├── README.md
├── install_redis.sh          # 二进制 RPM 安装
└── uninstall_redis.sh        # 卸载清理
```

---

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--port` | 监听端口 | 6379 |
| `--password` | requirepass 密码 | Redis1@zendao2024 |
| 环境变量 `REDIS_PORT` | 同 --port | 6379 |
| 环境变量 `REDIS_PASSWORD` | 同 --password | Redis1@zendao2024 |
| 环境变量 `DATA_DIR` | 数据目录 | /data/redis |
| 环境变量 `LOG_DIR` | 日志目录 | /var/log/redis |

---

## 默认配置

| 配置项 | 值 |
|--------|-----|
| 监听地址 | `0.0.0.0` |
| 最大内存 | 512MB |
| 淘汰策略 | `allkeys-lru` |
| 持久化 | RDB（snapshot）+ AOF（everysec） |
| supervised | systemd |
| 开机自启 | `systemctl enable redis` |

---

## 系统要求

| 资源 | 最低 |
|------|------|
| CPU | 1 Core |
| 内存 | 1 GB |
| 磁盘 | 2 GB |

---

## 管理命令

```bash
systemctl start redis          # 启动
systemctl stop redis           # 停止
systemctl restart redis        # 重启
systemctl status redis         # 状态
systemctl is-enabled redis     # 是否开机自启
journalctl -u redis -f         # 日志

# 连接
redis-cli -h 127.0.0.1 -p 6379 -a 'Redis1@zendao2024'
```

## 卸载

```bash
bash uninstall_redis.sh         # 保留 /data/redis
bash uninstall_redis.sh --data  # 全部清理（含数据 + RPM + 用户）
```

---

## TODO

- [ ] 源码编译模式（TLS 支持）：`redis-7.4.1.tar.gz → make BUILD_TLS=yes`
- [ ] Sentinel 哨兵模式
- [ ] Cluster 集群模式
