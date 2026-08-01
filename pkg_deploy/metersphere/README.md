# MeterSphere 部署

> 源码构建 + 裸机 systemd 进程 / Docker 容器，两种方式可选

---

## 前置：准备离线包

将以下文件放到 `build/` 目录或 `/tmp/build-cache/`，构建时无需联网：

| 包 | 文件名 | 用途 |
|---|--------|------|
| JDK 17 | `OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz` | Java 编译运行 |
| Maven 3.9 | `apache-maven-3.9.16-bin.tar.gz` | 项目构建 |
| MeterSphere 源码 | `metersphere-v3.6.0.tar.gz` | 源码包（可选，脚本自动 git clone） |

> 脚本优先从同目录加载离线包，无则在线下载。

## 裸机部署（三步）

```bash
cd pkg_deploy/metersphere/build

# 1. 构建（git clone → Maven 编译 → JAR）
bash build_metersphere.sh v3.6.0

# 2. 安装 systemd 服务
bash install_metersphere.sh --port 8081 --db-host 192.168.10.5

# 3. 访问
# http://<IP>:8081
# 默认账号: admin / metersphere
```

## Docker 容器部署

### 方式一：全量编译（源码→容器，一键）

```bash
bash build_image.sh         # 默认 latest
bash build_image.sh v3.6.0  # 指定版本
```

### 方式二：预编译

```bash
bash build_metersphere.sh    # 先裸机构建
bash build_image.sh --prebuilt
```

### 启动容器

```bash
docker run -d --name metersphere \
  -p 8081:8081 \
  -e DB_HOST=192.168.10.5 \
  -e DB_PORT=3306 \
  -e DB_NAME=metersphere \
  -e DB_USER=root \
  -e DB_PASS=Password123!@# \
  -e REDIS_HOST=192.168.10.5 \
  -e KAFKA_BOOTSTRAP=192.168.10.5:9092 \
  harbor.testops.local/testops/metersphere:latest
```

### 构建 + 推送

```bash
bash build_image.sh --prebuilt push
HARBOR_URL=harbor.my.com bash build_image.sh --prebuilt push
```

---

## 离线包下载

```bash
# JDK 17（Eclipse Temurin）
wget -O OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz \
  "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz"

# Maven 3.9.16
wget https://dlcdn.apache.org/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.tar.gz

# MeterSphere 源码
git clone --depth 1 --branch v3.6.0 https://github.com/metersphere/metersphere.git /opt/metersphere
# 或打包
cd /opt/metersphere && tar -czf metersphere-v3.6.0.tar.gz .
```

## 自定义参数

```bash
# 指定版本
bash build_metersphere.sh v3.6.0

# 跳过 JDK/Maven（已安装时）
bash build_metersphere.sh --skip-jdk --skip-maven

# 指定端口和数据库
bash install_metersphere.sh --port 8082 --db-host 192.168.10.5 --db-port 3306

# JVM 内存
HEAP_MIN=4096m HEAP_MAX=8192m bash install_metersphere.sh

# 强制重装
bash install_metersphere.sh --force

# 指定 Redis / Kafka
bash install_metersphere.sh --redis-host 192.168.10.5 --kafka 192.168.10.5:9092
```

## 依赖中间件

| 中间件 | 状态 | 说明 |
|--------|------|------|
| MySQL 8.0 | 必需 | 部署目录: `../mysql8.0/` |
| Redis 7 | 必需 | 部署目录: `../redis7/` |
| Kafka | 建议 | 可选，部分功能需要 |
| JDK 17 | 必需 | 构建脚本自动安装 |

## 管理

```bash
systemctl status metersphere              # 状态
systemctl {start|stop|restart} metersphere
journalctl -u metersphere -f              # 日志
tail -f /var/log/metersphere/ms.log       # 应用日志
```

---

## 系统要求

| 资源 | 最低 | 建议 |
|------|------|------|
| CPU | 2 Cores | 4+ Cores |
| 内存 | 4 GB | 8 GB |
| 磁盘 | 20 GB | 50 GB |
| 数据库 | MySQL 8.0 | MySQL 8.0 |

---

## 目录结构

```
metersphere/
├── README.md
├── .gitignore
└── build/
    ├── build_metersphere.sh     # 源码 Maven 编译
    ├── install_metersphere.sh   # 裸机 systemd 安装
    ├── build_image.sh           # Docker 镜像构建
    ├── clean_metersphere.sh     # 卸载清理
    ├── Dockerfile               # 全量编译 Dockerfile
    ├── Dockerfile.prebuilt      # 预编译 Dockerfile
    └── docker-entrypoint.sh     # 容器入口
```
