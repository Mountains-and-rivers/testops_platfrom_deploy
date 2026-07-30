# Redis 7.4.1 — 单机部署

> 二进制 RPM 安装（dnf/Remi），快速编译回退

---

## 一键执行

```bash
# 安装（二进制 RPM / dnf 优先，本地包优先）
bash install_redis.sh

# 指定端口和密码
bash install_redis.sh --port 6379 --password MyPass123

# 卸载（保留 /data/redis）
bash uninstall_redis.sh

# 卸载（含数据）
bash uninstall_redis.sh --data
```

---

## 版本信息

| 项目 | 值 |
|------|-----|
| Redis | **7.4.1** |
| 二进制包 | `redis-7.4.1-1.el9.remi.x86_64.rpm`（Remi） |
| 备用 | `redis-7.4.1.tar.gz`（快速编译，~2 分钟） |

---

## 安装流程

```
[0/6] 已安装检测  →  版本一致则跳过
[1/6] 获取包      →  本地 RPM → dnf 安装 → 本地源码 → 下载源码
[2/6] 安装        →  rpm -ivh / dnf / 快速编译
[3/6] 配置        →  用户 + redis.conf（AOF + RDB）
[4/6] systemd     →  Type=notify + enable + start
[5/6] 功能验证    →  进程 + 端口 + PING + SET/GET
[6/6] 完成
```

---

## 目录结构

```
redis7/
├── .gitignore
├── README.md
├── install_redis.sh          # 二进制 RPM / 快速编译 安装
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
| 环境变量 `INSTALL_DIR` | 安装目录 | /usr/local/redis |
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
journalctl -u redis -f         # 日志

# 连接
redis-cli -h 127.0.0.1 -p 6379 -a Redis1@zendao2024
```

## 卸载

```bash
bash uninstall_redis.sh         # 保留 /data/redis
bash uninstall_redis.sh --data  # 全部清理
```

---

## TODO

- [ ] 源码编译模式（TLS 支持）：`redis-7.4.1.tar.gz → make BUILD_TLS=yes`
- [ ] Sentinel 哨兵模式
- [ ] Cluster 集群模式
