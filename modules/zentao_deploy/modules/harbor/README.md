# Harbor 镜像仓库部署

> 源码编译 + 极简 CentOS 9 基础镜像 + Docker Compose

---

## 一键执行

```bash
# 第 1 步：构建极简基础镜像（仅一次，~1 分钟）
bash build/build_base.sh

# 第 2 步：编译 Harbor + 构建组件镜像（~15-20 分钟）
bash build/build_local.sh 2.11.0 harbor.testops.local/testops

# 第 3 步：启动 Harbor（外部访问必须用 IP）
bash build/install_harbor.sh 2.11.0 192.168.0.102 Harbor12345 harbor.testops.local/testops

# 第 4 步：浏览器访问
#   https://192.168.0.102
#   账号: admin  密码: Harbor12345
#   忽略自签名证书警告即可

# 清理（需要时）
bash build/clean_harbor.sh              # 保留 /data/harbor
bash build/clean_harbor.sh --data       # 含数据全清
```

---

## 原理

```
centos:stream9 (245MB)                     ← Docker Hub / quay.io / 本地 tar
  ├── goharbor/photon:5.0 (471MB)          ← build_base.sh  极简运行时（tzdata shadow curl openssl cronie logrotate）
  │     └── Harbor 组件 Dockerfile 直接 FROM goharbor/photon:5.0
  │           make build 编译 Go 二进制 → COPY 到极简镜像 → 最终组件 ~500-900MB
  │
  ├── golang:1.26.4 (~1.75GB)              ← build_local.sh  FROM centos:stream9 + gcc/make/dpkg/python3 + Go
  └── node:22.22.3 (~1.6GB)                ← build_local.sh  FROM centos:stream9 + gcc/make/dpkg/python3 + Node.js

编译镜像（golang/node）仅构建时使用，不进入最终组件镜像。
```

---

## 前置条件

目标机器需安装 Docker（≥20.10）和 Docker Compose。

`centos:stream9` 拉取优先级：**Docker Hub → quay.io → 本地 `centos-stream9.tar`**

如 Docker Hub 不可达，配置镜像加速：

```bash
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.mirrors.ustc.edu.cn",
    "https://docker.nju.edu.cn",
    "https://dockerproxy.com",
    "https://mirror.ccs.tencentyun.com",
    "https://hub-mirror.c.163.com"
  ]
}
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
```

---

## 文件说明

| 文件 | 用途 |
|------|------|
| `build/build_base.sh` | 构建极简 `goharbor/photon:5.0`（~471MB），仅一次 |
| `build/build_local.sh` | 编译 Harbor 源码 + 构建组件镜像 + 修复 prepare |
| `build/install_harbor.sh` | 生成配置 + Docker Compose 一键启动 |
| `build/clean_harbor.sh` | 停止容器 + 删镜像/目录/数据/端口 |
| `build/centos.repo` | 阿里云 CentOS + EPEL 源 |

### 离线包（放 `build/` 脚本同目录，本地优先）

| 文件 | 大小 | 用途 |
|------|------|------|
| `harbor.zip` | 269MB | Harbor 源码 |
| `go1.26.4.linux-amd64.tar.gz` | 64MB | Go 编译器 |
| `node-v22.22.3-linux-x64.tar.xz` | 30MB | Node.js |
| `dpkg_1.22.22.tar.xz` | 5.5MB | dpkg 源码（Harbor 工具链依赖） |
| `spectral-linux-x64` | 85MB | API 校验 |
| `centos.repo` | 1.4KB | 阿里云源配置 |
| `centos-stream9.tar` | 59MB | CentOS Stream 9 基础镜像 |
| `goharbor-photon-5.0.tar` | 135MB | 构建产物（可跳过 build_base.sh） |
| `valkey-9-alpine.tar` | 17MB | Valkey 缓存 |
| `registry-2.tar` | 10MB | Docker Registry |
| `postgres-15-alpine.tar` | 110MB | PostgreSQL 数据库 |

---

## 构建产物

> 共 11 个组件：

```
源码编译 make build（6 个）:
  goharbor/harbor-core:v2.11.0           goharbor/harbor-portal:v2.11.0
  goharbor/harbor-jobservice:v2.11.0     goharbor/harbor-log:v2.11.0
  goharbor/nginx-photon:v2.11.0          goharbor/prepare:v2.11.0

daocloud 拉取 / 本地 tar（5 个）:
  goharbor/harbor-db:v2.11.0            ← postgres:15-alpine
  goharbor/harbor-valkey:v2.11.0        ← valkey/valkey:9-alpine
  goharbor/harbor-registry:v2.11.0      ← registry:2
  goharbor/harbor-registryctl:v2.11.0   ← 官方镜像
  goharbor/harbor-exporter:v2.11.0      ← 官方镜像
```

---

## 访问

- **外部**: `https://192.168.0.102` （忽略证书警告）
- **账号**: `admin` / `Harbor12345`
- **本机 hosts**: `192.168.0.102 harbor.testops.local`

![Harbor 登录页](/docs/images/harbor_test_result.png)

## 使用 Harbor

### 本机推送 / 拉取

```bash
# 登录
docker login 192.168.0.102 -u admin -p Harbor12345

# 推送
docker tag nginx:latest 192.168.0.102/testops/nginx:v1.0
docker push 192.168.0.102/testops/nginx:v1.0

# 拉取
docker pull 192.168.0.102/testops/nginx:v1.0
```

### 其他机器推送 / 拉取

先配 insecure-registries（自签名证书必须）：

```bash
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "insecure-registries": ["192.168.0.102"]
}
EOF
sudo systemctl restart docker
```

然后同样操作：

```bash
docker login 192.168.0.102 -u admin -p Harbor12345
docker tag nginx:latest 192.168.0.102/testops/nginx:v1.0
docker push 192.168.0.102/testops/nginx:v1.0
docker pull 192.168.0.102/testops/nginx:v1.0
```

---

## 卸载

```bash
bash build/clean_harbor.sh              # 保留 /data/harbor
bash build/clean_harbor.sh --data       # 含数据全清
```

清理范围：容器 11 个 → 目录 6 个 → 临时文件 → 组件镜像 → 编译镜像 → 外部镜像 → 悬空+缓存+网络+卷 → 数据+防火墙

---

## 多源加速（参考）

```bash
# CentOS/DNF
cp centos.repo /etc/yum.repos.d/centos.repo
dnf install -y epel-release
printf '[epel]\nname=EPEL - Aliyun\nbaseurl=https://mirrors.aliyun.com/epel/$releasever/Everything/$basearch/\nenabled=1\ngpgcheck=0\n' > /etc/yum.repos.d/epel.repo

# Go / NPM / Pip
go env -w GOPROXY=https://goproxy.cn,direct
npm config set registry https://registry.npmmirror.com
pip3 config set global.index-url https://mirrors.aliyun.com/pypi/simple/
```

---

## 端口

| 端口 | 用途 |
|------|------|
| 443 | HTTPS API + Web UI |
| 80 | HTTP → HTTPS |
| 4443 | Registry Notary |
