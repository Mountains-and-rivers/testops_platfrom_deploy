# Jenkins 企业级部署

## 裸机 systemd 部署

```bash
cd /path/to/jenkins/build
bash build_jenkins.sh 2.479.1 && bash install_jenkins.sh
```
然后访问 `http://<IP>:8080`，初始密码：`cat /var/lib/jenkins/secrets/initialAdminPassword`

## 容器 Docker 部署

```bash
cd /path/to/jenkins/build
bash build_jenkins.sh 2.479.1 && bash build_image.sh --prebuilt
```
然后 `docker run -d --name jenkins -p 8080:8080 -p 50000:50000 -v jenkins_home:/var/lib/jenkins harbor.testops.local/testops/jenkins:2.479.1`

---

## 本地包

脚本查找顺序：**脚本同目录** → `/tmp/build-cache/` → 远程下载。也接受原始文件名模糊匹配。

| 包 | 另可接受的本地文件名 |
|---|-------------------|
| `jdk17.tar.gz` | `OpenJDK17U*.tar.gz` |
| `jdk11.tar.gz` | `OpenJDK11U*.tar.gz` |
| `jdk21.tar.gz` | `OpenJDK21U*.tar.gz` |
| `apache-maven-3.9.16-bin.tar.gz` | `apache-maven-*.tar.gz` |
| `jenkins-2.479.1.zip` | `jenkins.zip` |

## 下载（网络环境差时提前下好放上面目录）

```bash
# JDK 17（Jenkins 2.463+ 默认，Eclipse Temurin 二进制包）
wget -O jdk17.tar.gz \
  "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_x64_linux_hotspot_17.0.19_10.tar.gz"

# Maven 3.9.16
wget -O apache-maven-3.9.16-bin.tar.gz \
  https://dlcdn.apache.org/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.tar.gz

# Jenkins 2.479.1 源码
wget -O jenkins-2.479.1.zip \
  https://github.com/jenkinsci/jenkins/archive/refs/tags/jenkins-2.479.1.zip

# CentOS 容器镜像（仅 Docker 部署）
docker pull quay.io/centos/centos:stream9 && docker tag quay.io/centos/centos:stream9 centos:stream9
docker save centos:stream9 -o centos-stream9.tar
```

## 自定义参数

```bash
# 端口
bash install_jenkins.sh --port 9090

# JVM 内存
HEAP_MIN=4096m HEAP_MAX=8192m bash install_jenkins.sh

# 强制重装
bash install_jenkins.sh --force

# JDK 版本
JDK_VERSION=21 bash build_jenkins.sh

# 推送到 Harbor
bash build_image.sh --prebuilt push
HARBOR_URL=harbor.my.com HARBOR_PROJECT=ci bash build_image.sh --prebuilt push
```

## 管理

```bash
systemctl status jenkins        # 状态
systemctl restart jenkins       # 重启
journalctl -u jenkins -f        # 日志
bash clean_jenkins.sh --yes     # 卸载
```
