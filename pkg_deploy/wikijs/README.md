# Wiki.js 部署

> 源码构建 + 裸机 systemd 进程 / Docker 容器，两种方式可选

---

## 前置：准备离线包

将以下文件放到 `build/` 目录或 `/tmp/build-cache/`，构建时无需联网：

| 包 | 文件名 | 用途 |
|---|--------|------|
| Node.js 22.x | `node-v22.20.0-linux-x64.tar.xz` | Node.js 运行时 |
| Wiki.js 源码 | `wiki-main.tar.gz` / `wiki-3.0.tar.gz` | 源码包（可选，脚本自动 git clone） |

> 脚本优先从同目录加载离线包，无则在线下载。

## 裸机部署（三步）

```bash
cd pkg_deploy/wikijs/build

# 1. 构建（git clone → npm install → npm build）
bash build_wikijs.sh main

# 2. 安装 systemd 服务
bash install_wikijs.sh --port 3000 --db-host 192.168.10.5

# 3. 访问
# http://<IP>:3000
```

## Docker 容器部署

### 方式一：全量编译（源码→容器，一键）

```bash
bash build_image.sh        # 默认 latest
bash build_image.sh 3.0.0  # 指定版本
```

### 方式二：预编译

```bash
bash build_wikijs.sh        # 先裸机构建
bash build_image.sh --prebuilt
```

### 启动容器

```bash
docker run -d --name wiki \
  -p 3000:3000 \
  -e DB_HOST=192.168.10.5 \
  -e DB_PORT=5432 \
  -e DB_NAME=wiki \
  -e DB_USER=postgres \
  -e DB_PASS=Pg1@zendao2024 \
  harbor.testops.local/testops/wiki:latest
```

### 构建 + 推送

```bash
bash build_image.sh --prebuilt push
HARBOR_URL=harbor.my.com bash build_image.sh --prebuilt push
```

---

## 离线包下载

```bash
# Node.js 22.20.0
wget https://nodejs.org/dist/v22.20.0/node-v22.20.0-linux-x64.tar.xz

# Wiki.js 源码（git clone 或 tarball）
git clone --depth 1 https://github.com/requarks/wiki.git /opt/wiki
# 或打包
cd /opt/wiki && tar -czf wiki-main.tar.gz .
```

## 自定义参数

```bash
# 指定版本
bash build_wikijs.sh v3.0.0

# 指定端口
bash install_wikijs.sh --port 3001

# 指定数据库（已有 postgresql18 部署）
bash install_wikijs.sh --db-host 192.168.10.5 --db-port 5432 --db-name wiki --db-user postgres --db-pass Pg1@zendao2024

# 强制重装
bash install_wikijs.sh --force
```

## 管理

```bash
systemctl status wiki              # 状态
systemctl {start|stop|restart} wiki
journalctl -u wiki -f              # 日志
tail -f /var/log/wiki/wiki.log     # 应用日志
```

---

## 系统要求

| 资源 | 最低 | 建议 |
|------|------|------|
| CPU | 1 Core | 2 Cores |
| 内存 | 1 GB | 2 GB |
| 磁盘 | 5 GB | 10 GB |
| 数据库 | PostgreSQL 12+ | PostgreSQL 18 |

---

## 目录结构

```
wikijs/
├── README.md
├── .gitignore
└── build/
    ├── build_wikijs.sh          # 源码构建
    ├── install_wikijs.sh        # 裸机 systemd 安装
    ├── build_image.sh           # Docker 镜像构建
    ├── clean_wikijs.sh          # 卸载清理
    ├── Dockerfile               # 全量编译 Dockerfile
    ├── Dockerfile.prebuilt      # 预编译 Dockerfile
    └── docker-entrypoint.sh     # 容器入口
```
