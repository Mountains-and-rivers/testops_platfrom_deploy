# Harbor 镜像仓库部署

> 源码编译 + 极简 CentOS 9 基础镜像 + Docker Compose

---

## 快速执行

```bash
# 第 1 步：构建极简基础镜像（仅一次，~2 分钟）
bash build/build_base.sh

# 第 2 步：编译 Harbor + 构建组件镜像（~15-20 分钟）
bash build/build_local.sh 2.11.0 harbor.testops.local/testops

# 第 3 步：启动 Harbor（外部访问用 IP）
bash build/install_harbor.sh 2.11.0 192.168.0.102 Harbor12345 harbor.testops.local/testops

# 第 4 步：访问
#   https://192.168.0.102
#   账号: admin  密码: Harbor12345
#   忽略证书警告

# 清理
bash build/clean_harbor.sh --data
```

---

## 原理

```
centos:stream9 (245MB)
  └── goharbor/photon:5.0 (471MB)    ← build_base.sh  极简运行时，仿官方 Photon
        ├── Harbor 组件 Dockerfile 直接 FROM goharbor/photon:5.0
        └── make build 编译 Go 二进制 → COPY 到极简镜像

golang:1.26.4 (1.75GB)              ← build_local.sh  编译工具镜像
node:22.22.3 (1.6GB)                ← build_local.sh  编译 Portal 用
```

**仿官方做法**：基础镜像只装运行时包（tzdata/shadow/openssl/curl/cronie/logrotate），不含 gcc/python3/dpkg。编译工具在 golang/node 镜像里，不进入最终组件镜像。

---

## 文件说明

| 文件 | 用途 |
|------|------|
| `build/build_base.sh` | 构建极简 goharbor/photon:5.0（~471MB） |
| `build/build_local.sh` | 编译 Harbor 源码 + 构建组件镜像 |
| `build/install_harbor.sh` | Docker Compose 部署 Harbor |
| `build/clean_harbor.sh` | 卸载清理 |
| `build/harbor.zip` | Harbor v2.11.0 源码 |

### 离线包（放脚本同目录，优先使用）

| 文件 | 大小 | 用途 |
|------|------|------|
| `harbor.zip` | 269MB | Harbor 源码 |
| `go1.26.4.linux-amd64.tar.gz` | 64MB | Go 编译器 |
| `node-v22.22.3-linux-x64.tar.xz` | 30MB | Node.js |
| `dpkg_1.22.22.tar.xz` | 5.5MB | dpkg 源码 |
| `spectral-linux-x64` | 85MB | API 校验 |
| `centos.repo` | 1.4KB | 阿里云源配置 |
| `centos-stream9.tar` | 59MB | CentOS 基础镜像 |
| `goharbor-photon-5.0.tar` | 135MB | 构建产物 |
| `valkey-9-alpine.tar` | 17MB | Valkey 缓存 |
| `registry-2.tar` | 10MB | Docker Registry |
| `postgres-15-alpine.tar` | 110MB | PostgreSQL 数据库 |

---

## 镜像结构（构建产物）

```
Harbor v2.11.0 组件（源码编译）:
  goharbor/harbor-core:v2.11.0         goharbor/harbor-portal:v2.11.0
  goharbor/harbor-jobservice:v2.11.0   goharbor/harbor-log:v2.11.0
  goharbor/nginx-photon:v2.11.0       goharbor/prepare:v2.11.0

外部拉取（daocloud 镜像源）:
  goharbor/harbor-db:v2.11.0 (postgres:15)     goharbor/harbor-valkey:v2.11.0
  goharbor/harbor-registry:v2.11.0            goharbor/harbor-registryctl:v2.11.0
  goharbor/harbor-exporter:v2.11.0
```

---

## Docker 代理与镜像加速

### Registry Mirror（国内直连，无需代理）

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
docker info | grep -A10 "Registry Mirrors"
```

### HTTP 代理（106 服务器，Mirror 不可用时）

```bash
PROXY_URL="http://192.168.0.106:7890"
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf << EOF
[Service]
Environment="HTTP_PROXY=${PROXY_URL}"
Environment="HTTPS_PROXY=${PROXY_URL}"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,.local,.internal"
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
```

---

## 多源加速

```bash
# CentOS/DNF 阿里云
cp centos.repo /etc/yum.repos.d/centos.repo

# EPEL 阿里云
dnf install -y epel-release
printf '[epel]\nname=EPEL - Aliyun\nbaseurl=https://mirrors.aliyun.com/epel/$releasever/Everything/$basearch/\nenabled=1\ngpgcheck=0\n' > /etc/yum.repos.d/epel.repo

# Go / NPM / Pip
go env -w GOPROXY=https://goproxy.cn,direct
npm config set registry https://registry.npmmirror.com
pip3 config set global.index-url https://mirrors.aliyun.com/pypi/simple/
```

---

## 访问

- **外部**: `https://192.168.0.102` （忽略证书警告）
- **账号**: `admin` / `Harbor12345`
- **本机 hosts**: `192.168.0.102 harbor.testops.local`

![Harbor 登录页](/docs/images/harbor_test_result.png)

## 使用 Harbor

```bash
docker login 192.168.0.102 -u admin -p Harbor12345
docker tag myapp:latest 192.168.0.102/testops/myapp:latest
docker push 192.168.0.102/testops/myapp:latest
```

> 其他节点: `{"insecure-registries":["192.168.0.102"]}`

---

## 卸载

```bash
bash build/clean_harbor.sh              # 保留 /data/harbor
bash build/clean_harbor.sh --data       # 全清
```

---

## 端口

| 端口 | 用途 |
|------|------|
| 443 | HTTPS API + Web UI |
| 80 | HTTP → HTTPS |
| 4443 | Registry Notary |
