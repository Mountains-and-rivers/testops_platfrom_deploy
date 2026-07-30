# Jenkins 企业级部署

## 前置：准备离线包

将以下文件放到脚本同目录或 `/tmp/build-cache/`，构建时无需联网：

| 包 | 文件名 | 用途 |
|---|--------|------|
| JDK 17 | `OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz` | Java 编译运行（2.463+） |
| JDK 21 | `OpenJDK21U-jdk_x64_linux_hotspot_21.0.9_10.tar.gz` | Java 编译运行（2.555+） |
| JDK 11 | `OpenJDK11U-jdk_x64_linux_hotspot_11.0.25_9.tar.gz` | Java 编译运行（2.361+） |
| Maven | `apache-maven-3.9.16-bin.tar.gz` | 项目构建 |
| Node.js | `node-v24.18.0-linux-x64.tar.gz` | 前端编译（版本必须与 pom.xml 一致） |
| Jenkins 源码 | `jenkins.zip` | 源码包 |

> **Node.js 版本匹配**：脚本会从 `pom.xml` 中读取 `<node.version>`，自动比对本地包版本。一致则预填充 Maven 缓存让 `frontend-maven-plugin` 跳过下载；不一致则跳过全部前端 goal 使用预编译资源。

## 裸机部署（三步）

```bash
cd /path/to/jenkins/build

# 1. 编译（约 10-30 分钟）
bash build_jenkins.sh 2.479.1

# 2. 安装 systemd 服务
bash install_jenkins.sh

# 3. 访问
# http://<IP>:8080
# 初始密码: cat /var/lib/jenkins/secrets/initialAdminPassword
```

## 快速启动（跳过 systemd 安装）

构建完成后可直接用 `java -jar` 启动验证：

```bash
export JENKINS_HOME=/var/lib/jenkins
export JAVA_HOME=/opt/jdk21
mkdir -p $JENKINS_HOME

nohup /opt/jdk21/bin/java \
  -Xmx2048m \
  -Dhudson.security.csrf.DefaultCrumbIssuer.EXCLUDE_SESSION_ID=true \
  -jar /opt/jenkins/jenkins.war \
  --httpPort=8080 \
  --httpListenAddress=0.0.0.0 \
  > /var/log/jenkins.log 2>&1 &

# 查看初始密码
cat /var/lib/jenkins/secrets/initialAdminPassword
```

> JDK 版本取决于 jenkins.war 的实际编译版本：2.576-SNAPSHOT → JDK 21，2.479.1 → JDK 17。

## 插件预下载（国内镜像加速）

网络环境差时（如 `java.net.SocketException: Connection reset` 问题），可在启动 Jenkins 前从国内镜像预下载插件：

```bash
# 下载建议插件到 /var/lib/jenkins/plugins（裸机）
MIRROR=ustc PREINSTALL_SCRIPT=./preinstall_plugins.sh bash install_jenkins.sh

# 或单独运行
bash preinstall_plugins.sh                           # 默认 21 个建议插件
bash preinstall_plugins.sh --plugin-list "git,ldap"   # 指定插件
bash preinstall_plugins.sh --from-file plugins.txt    # 从文件读取
```

**可用镜像**：`ustc`（中科大，默认）、`tsinghua`（清华）

**支持的插件下载镜像**：
| 镜像 | URL | 状态 |
|------|-----|------|
| USTC | `https://mirrors.ustc.edu.cn/jenkins/plugins` | ✅ 推荐 |
| 清华 | `https://mirrors.tuna.tsinghua.edu.cn/jenkins/plugins` | ✅ 可用 |

**注意**：国内镜像只镜像 `plugins/`，不提供 `update-center.json`。更新中心元数据仍从 `updates.jenkins.io` 获取（脚本已自动处理）。

## 容器 Docker 部署

### 方式一：全量编译（源码→容器，一键）

无需预先执行 `build_jenkins.sh`，Docker 内完成 git clone → 编译 → 镜像：

```bash
cd /path/to/jenkins/build
bash build_image.sh
```

> 要求：Docker 构建环境能访问 GitHub（git clone）和 Maven Central。Node.js 离线包会自动传入容器。

### 方式二：预编译 WAR（两步）

先裸机编译，再用 WAR 构建镜像（适合离线/无 GitHub 环境）：

```bash
cd /path/to/jenkins/build
bash build_jenkins.sh 2.479.1
bash build_image.sh --prebuilt
```

### 启动容器

```bash
docker run -d --name jenkins \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/lib/jenkins \
  -e JENKINS_PLUGIN_MIRROR=https://mirrors.ustc.edu.cn/jenkins/plugins \
  harbor.testops.local/testops/jenkins:2.479.1
```

> **插件预下载**：设置 `JENKINS_PLUGIN_MIRROR` 环境变量后，容器首次启动会自动从国内镜像预下载建议插件，无需从 `updates.jenkins.io` 下载。
> 使用 `JENKINS_PREINSTALL_PLUGINS` 可指定要预下载的插件列表（逗号分隔）。

### 构建 + 推送

```bash
bash build_image.sh --prebuilt push                   # 预编译
bash build_image.sh push                              # 全量编译 + 推送
HARBOR_URL=harbor.my.com HARBOR_PROJECT=ci bash build_image.sh --prebuilt push
```

---

## 下载离线包（网络环境差时提前准备）

```bash
# JDK 17（Jenkins 2.463+，Eclipse Temurin）
wget -O OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz \
  "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jdk_x64_linux_hotspot_17.0.13_11.tar.gz"

# JDK 21（Jenkins 2.555+，Eclipse Temurin）
wget -O OpenJDK21U-jdk_x64_linux_hotspot_21.0.9_10.tar.gz \
  "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.9%2B10/OpenJDK21U-jdk_x64_linux_hotspot_21.0.9_10.tar.gz"

# JDK 11（Jenkins 2.361+，Eclipse Temurin）
wget -O OpenJDK11U-jdk_x64_linux_hotspot_11.0.25_9.tar.gz \
  "https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.25%2B9/OpenJDK11U-jdk_x64_linux_hotspot_11.0.25_9.tar.gz"

# Maven 3.9.16
wget -O apache-maven-3.9.16-bin.tar.gz \
  https://dlcdn.apache.org/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.tar.gz

# Node.js（版本需与 pom.xml 中 <node.version> 一致）
wget -O node-v24.18.0-linux-x64.tar.gz \
  https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.gz

# Jenkins 2.479.1 源码
wget -O jenkins-2.479.1.zip \
  https://github.com/jenkinsci/jenkins/archive/refs/tags/jenkins-2.479.1.zip

# CentOS 容器镜像（仅 Docker 部署）
docker pull quay.io/centos/centos:stream9 && docker tag quay.io/centos/centos:stream9 centos:stream9
docker save centos:stream9 -o centos-stream9.tar.gz
```

## 自定义参数

```bash
# 指定版本
bash build_jenkins.sh 2.479.2

# 端口
bash install_jenkins.sh --port 9090

# JVM 内存
HEAP_MIN=4096m HEAP_MAX=8192m bash install_jenkins.sh

# 强制重装
bash install_jenkins.sh --force

# JDK 版本（覆盖自动检测）
JDK_VERSION=21 bash build_jenkins.sh

# 推送到 Harbor
bash build_image.sh --prebuilt push
HARBOR_URL=harbor.my.com HARBOR_PROJECT=ci bash build_image.sh --prebuilt push
```

## 管理

```bash
# ── 裸机 systemd ──
systemctl status jenkins        # 状态
systemctl restart jenkins       # 重启
journalctl -u jenkins -f        # 日志

# ── Docker 容器 ──
docker restart jenkins          # 重启容器
docker logs -f jenkins          # 查看日志
docker start jenkins            # 启动已停止的容器

# ── 清理（选项: -a 全部 -j 服务 -b 构建 -c 缓存 -u 用户 -m JDK/Maven）
bash clean_jenkins.sh -a --yes  # 全部卸载
bash clean_jenkins.sh -b        # 仅清理构建产物
```
