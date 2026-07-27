# Zentao Deploy — 禅道企业级 TestOps 自动化部署工程

> 基于官方源码构建、K8s 部署、Jenkins CI/CD 集成、外部 MySQL 独立架构的企业级禅道部署解决方案。
> 禅道开源版 GitHub: [easysoft/zentaopms](https://github.com/easysoft/zentaopms) | 当前版本: **v21.2**

---

## 目录

1. [项目结构](#项目结构)
2. [硬件与前置环境要求](#硬件与前置环境要求)
3. [第一步：工作站环境准备](#第一步工作站环境准备)
4. [第二步：外部 MySQL 数据库准备](#第二步外部-mysql-数据库准备)
5. [第三步：编译服务器环境准备](#第三步编译服务器环境准备)
6. [第四步：拉取源码并构建 Docker 镜像](#第四步拉取源码并构建-docker-镜像)
7. [第五步：推送镜像到 Harbor 私有仓库](#第五步推送镜像到-harbor-私有仓库)
8. [第六步：部署禅道到 Kubernetes](#第六步部署禅道到-kubernetes)
9. [第七步：部署后健康验证](#第七步部署后健康验证)
10. [第八步：禅道初始化配置](#第八步禅道初始化配置)
11. [一键部署 / 一键销毁](#一键部署--一键销毁)
12. [CLI 命令参考](#cli-命令参考)
13. [硬性约束与规范](#硬性约束与规范)
14. [数据持久化官方标准](#数据持久化官方标准)
15. [Jenkins CI/CD 流水线](#jenkins-cicd-流水线)
16. [运维配套方案](#运维配套方案)
17. [远期扩展规划](#远期扩展规划)

---

## 项目结构

```
zentao_deploy/
├── README.md                              # 工程总文档（当前文件）
├── requirements.txt                       # Python 依赖清单
├── .gitignore                             # Git 忽略规则（密钥、日志、源码缓存）
├── main.py                                # 全局 CLI 入口（Click 实现）
│
├── configs/                               # 配置目录（业务代码与配置完全分离）
│   ├── global.yaml                        # 全局配置：Harbor地址、K8s集群、外部MySQL、版本
│   ├── env/template.env                   # 环境变量模板（纳入版本管理）
│   └── k8s_base/                          # K8s 通用基础资源模板
│
├── common/                                # 全局公共工具包（所有模块共享）
│   ├── log_utils.py                       # 统一日志（控制台彩色 + 文件滚动）
│   ├── ssh_client.py                      # Paramiko SSH 远程执行封装
│   ├── harbor_client.py                   # Harbor v2 API 封装
│   ├── k8s_client.py                      # kubectl 统一封装
│   ├── yaml_render.py                     # YAML 读写 + ${VAR} 模板渲染
│   ├── pre_check.py                       # 环境预检：磁盘/网络/Docker/必要命令
│   └── cli.py                             # CLI 命令通用异常捕获
│
├── modules/
│   ├── zentao/                            # 核心模块：禅道开源版
│   │   ├── build/                         # CentOS Stream9 源码构建镜像
│   │   │   ├── Dockerfile                 # 多阶段编译 Dockerfile
│   │   │   ├── .dockerignore
│   │   │   ├── docker-entrypoint.sh       # 容器入口脚本
│   │   │   ├── build_image.py             # 拉取→构建→打Tag→推送 Harbor
│   │   │   └── build_support.sh           # 编译环境一键初始化脚本
│   │   ├── manifests/                     # 禅道 K8s 资源清单（无 MySQL yaml）
│   │   ├── plugin_mgr/                    # 插件管理（在线/离线安装）
│   │   ├── workflow/                      # install / upgrade / destroy
│   │   └── verify/                         # health_check
│   └── java_app_cicd/                     # Java 业务应用 CI/CD 配套
│
├── workflows/                              # 跨模块串联完整业务工作流
│   ├── full_zentao_deploy.py              # 构建→推送→部署→验证 全链路
│   └── full_destroy.py                    # 一键清理 K8s 全部业务资源
│
├── logs/        # 运行日志（git 忽略）
├── temp/        # 临时文件（git 忽略）
└── docs/        # 扩展文档
```

---

## 硬件与前置环境要求

### 所需服务器清单

| 角色 | 数量 | 操作系统 | 最低配置 | 推荐配置 | 用途 |
|------|------|---------|---------|---------|------|
| **编译服务器** | 1 | CentOS Stream 9 | 4C/8G/50G | 8C/16G/100G | 源码编译构建 Docker 镜像 |
| **K8s 集群** | 已有 | Linux（CentOS/Ubuntu） | K8s ≥ v1.21 | K8s ≥ v1.27 | 运行禅道容器 |
| **MySQL 服务器** | 1 | CentOS Stream 9 / Ubuntu | 2C/4G/100G | 4C/8G/200G | 外部数据库（独立部署） |
| **Harbor 镜像仓库** | 1 | Linux | 2C/4G/100G | 4C/8G/200G | 私有 Docker 镜像仓库 |
| **工作站** | 1 | Windows/Linux/Mac | — | — | 执行部署脚本 |

### 网络连通性要求

```
工作站  ──SSH:22──→  编译服务器（CentOS Stream 9）
工作站  ──HTTPS:443──→  Harbor 镜像仓库
工作站  ──HTTPS:6443──→  K8s API Server
禅道 Pod  ──TCP:3306──→  外部 MySQL 服务器
```

### 依赖组件版本矩阵

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Python | ≥ 3.9 | 工作站运行部署脚本 |
| Docker | ≥ 20.10 | 编译服务器构建镜像 |
| kubectl | ≥ v1.21 | 工作站操作 K8s |
| MySQL | 8.0.35 | 外部数据库（utf8mb4 字符集） |
| Harbor | ≥ v2.8 | 私有镜像仓库 |
| K8s | v1.21 ~ v1.36 | 容器编排平台 |
| Ingress Controller | nginx-ingress ≥ 1.9 | 域名路由 |
| StorageClass | NFS / Ceph / GlusterFS | PVC 持久化存储 |

---

## 第一步：工作站环境准备

<> 操作位置：部署工作站（Windows/Linux/Mac）

### 1.1 安装 Python 依赖

```bash
cd D:\testops_platfrom_deploy\modules\zentao_deploy
pip install -r requirements.txt
```

### 1.2 验证必要工具

```bash
python --version     # ≥ 3.9
kubectl version      # 确保已配置 kubeconfig
docker --version     # 如本地需要构建
```

### 1.3 配置全局参数

编辑 `configs/global.yaml`，根据实际环境修改：

```yaml
# 必须修改的字段（标注 ★）
harbor:
  url: "https://harbor.testops.local"     # ★ Harbor 地址
  username: "admin"                        # ★ Harbor 用户名
  project: "testops"

kubernetes:
  namespace: "zentao"                      # ★ K8s 命名空间
  ingress_host: "zentao.testops.local"     # ★ 外部访问域名
  storage_class: "nfs-client"              # ★ 根据集群 StorageClass 修改

mysql:
  host: "192.168.0.100"                    # ★ 外部 MySQL 地址
  port: 3306
  user: "zentao"
  database: "zentao"

build_server:
  host: "192.168.0.100"                    # ★ 编译服务器地址
  port: 22
  username: "root"
  build_dir: "/opt/build/zentaopms"
```

### 1.4 配置环境变量（密码等敏感信息）

```bash
cp configs/env/template.env configs/env/test.env
vim configs/env/test.env
```

填入真实密码：
```ini
HARBOR_PASSWORD=YourHarborPassword123!
MYSQL_PASSWORD=YourMysqlPassword456!
BUILD_SERVER_PASSWORD=YourBuildServerPassword789!
```

---

## 第二步：外部 MySQL 数据库准备

### 2.1 一键安装 MySQL 8.0.35（推荐）

```bash
# SSH 登录 MySQL 服务器，上传 install_mysql.sh + mysql-8.0.35-linux-glibc2.28-x86_64.tar.xz
ssh root@192.168.0.102
cd /home/zendao && bash install_mysql.sh
```

脚本自动完成：停止残留 mysqld → 解压安装 → 创建 mysql 用户 → 生成 /etc/my.cnf → 初始化数据目录 → systemd 启动 → 改 root 密码 → 创建 zendao 库。

### 2.2 连接信息

| 配置项 | 值 |
|--------|-----|
| 地址 | `192.168.0.102:3306` |
| 账号 | `root` |
| 密码 | `Kd9$prL7sQ2!vzB4` |
| 数据库 | `zendao` |
| 数据目录 | `/data/mysql` |
| 日志目录 | `/var/log/mysql` |

### 2.3 卸载 MySQL

```bash
bash uninstall_mysql.sh
```

### 2.4 MySQL 配置（/etc/my.cnf 自动生成）

| 配置项 | 值 |
|--------|-----|
| character-set-server | utf8mb4 |
| default-authentication-plugin | mysql_native_password |
| innodb_buffer_pool_size | 512M |
| log_error_max_size | 128M（自动轮转） |
| binlog_expire_logs_seconds | 604800 |
| max_allowed_packet | 64M |

---

## 第三步：编译服务器环境准备

### 3.1 上传部署文件到 CentOS 9 编译服务器

将以下文件复制到编译服务器的 `/home/zendao/` 目录：

```bash
# 脚本文件
scp modules/zentao_deploy/modules/zentao/build/build_php.sh        root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/zentao/build/build.sh            root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/zentao/build/clean_php.sh        root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/zentao/build/Dockerfile          root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/zentao/build/Dockerfile.prebuilt root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/zentao/build/docker-entrypoint.sh root@192.168.0.102:/home/zendao/
# 源码包
scp modules/zentao_deploy/modules/zentao/build/zentaopms.zip       root@192.168.0.102:/home/zendao/
# 编译依赖包（可选，不传则自动下载）
scp modules/zentao_deploy/modules/zentao/build/libzip-1.10.1.tar.gz root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/zentao/build/onig-6.9.9.tar.gz   root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/zentao/build/httpd-2.4.62.tar.gz root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/zentao/build/php-8.1.27.tar.gz   root@192.168.0.102:/home/zendao/
# MySQL 安装文件
scp modules/zentao_deploy/modules/mysql8.0/install_mysql.sh         root@192.168.0.102:/home/zendao/
scp modules/zentao_deploy/modules/mysql8.0/uninstall_mysql.sh       root@192.168.0.102:/home/zendao/
```

### 3.2 裸机部署（编译 PHP/Apache + 初始化数据库 + 启动禅道）

```bash
ssh root@192.168.0.102
cd /home/zendao && bash build_php.sh
```

12 步全自动：安装依赖 → 编译 libzip/oniguruma → 编译 Apache → 编译 PHP → 解压源码 → 导入 zentao.sql（272 张表） → 写配置 → 启动。

访问：`http://192.168.0.102:8080/` 账号 `admin` 密码 `123456`

### 3.3 Docker 镜像构建 + 启动容器

```bash
# 构建镜像（自动选 prebuilt 快速模式或全量编译）
bash build.sh 21.2

# 启动容器
docker rm -f zentao; docker run -d --name zentao -p 8080:8080 \
  -e ZT_MYSQL_HOST=192.168.0.102 \
  -e ZT_MYSQL_PORT=3306 \
  -e ZT_MYSQL_USER=root \
  -e ZT_MYSQL_PASSWORD='Kd9$prL7sQ2!vzB4' \
  -e ZT_MYSQL_DB=zendao \
  harbor.testops.local/testops/zentao:21.2
```

### 3.4 清理环境

```bash
bash clean_php.sh        # 全部清理（= -a）
bash clean_php.sh -z     # 仅清理禅道源码，保留 PHP/Apache
bash clean_php.sh -p -d -c  # 清理编译产物 + 依赖库 + 缓存
```

### 3.2 编译期依赖组件表

| 序号 | 组件名称 | 作用 | 所属 yum 源 |
|------|---------|------|------------|
| 1 | `gcc` / `gcc-c++` | C/C++ 编译器 | baseos |
| 2 | `make` | 构建自动化 | baseos |
| 3 | `autoconf` | 生成 configure 脚本 | appstream |
| 4 | `libtool` | 共享库支持 | appstream |
| 5 | `bison` | 语法分析器生成器 | appstream |
| 6 | `re2c` | PHP 词法分析器 | appstream |
| 7 | `pkgconfig` | 库依赖查询 | baseos |
| 8 | `libxml2-devel` | XML 解析（PHP xml/dom） | appstream |
| 9 | `libpng-devel` | PNG 图像库（PHP gd） | appstream |
| 10 | `libjpeg-turbo-devel` | JPEG 图像库（PHP gd） | appstream |
| 11 | `freetype-devel` | TrueType 字体渲染（PHP gd） | appstream |
| 12 | `libzip-devel` | ZIP 压缩库（PHP zip） | appstream |
| 13 | `oniguruma-devel` | 正则表达式（PHP mbstring） | appstream |
| 14 | `openssl-devel` | SSL/TLS 加密 | baseos |
| 15 | `curl-devel` | URL 传输库 | baseos |
| 16 | `libicu-devel` | Unicode 国际化（PHP intl） | appstream |
| 17 | `sqlite-devel` | SQLite 头文件 | appstream |
| 18 | `httpd-devel` | Apache APR 开发库 | appstream |
| 19 | `git` | 源码版本控制 | appstream |
| 20 | `wget` | 文件下载 | appstream |
| 21 | `unzip` | ZIP 解压 | baseos |
| 22 | `docker` | 容器构建引擎 | docker-ce |
| 23 | `epel-release` | EPEL 扩展源 | — |

---

## 第四步：拉取源码并构建 Docker 镜像

### 4.1 Dockerfile 构建流程

```
Stage 1 (builder): centos:stream9
  ├── 安装编译依赖
  ├── COPY libzip-1.10.1.tar.gz → 编译
  ├── COPY onig-6.9.9.tar.gz → 编译
  ├── COPY httpd-2.4.62.tar.gz → ./configure → make → install → /opt/httpd
  ├── COPY php-8.1.27.tar.gz → ./configure → make → install → /opt/php
  └── PHP config + strip 二进制

Stage 2 (运行): centos:stream9
  ├── 安装运行依赖（mysql、apr、apr-util 等）
  ├── COPY --from=builder /opt/php + /opt/httpd
  ├── COPY source/ → /var/www/zentaopms/
  ├── 重写 httpd.conf（mod_mime + TypesConfig + PHP handler）
  ├── docker-entrypoint.sh
  └── HEALTHCHECK curl localhost:8080
```

### 4.2 构建模式

| 模式 | Dockerfile | 条件 | 速度 |
|------|-----------|------|------|
| 快速 | `Dockerfile.prebuilt` | `/opt/php` 和 `/opt/httpd` 存在 | 秒级 |
| 全量 | `Dockerfile` | 否则 | 5-15 分钟 |

### 4.3 构建命令

```bash
# 构建
bash build.sh 21.2

# 构建 + 推送到 Harbor
HARBOR_PASS='xxx' bash build.sh 21.2 push
```

---

## 第五步：推送镜像到 Harbor 私有仓库

### 5.1 构建并推送

```bash
HARBOR_PASS='xxx' bash build.sh 21.2 push
```

### 5.2 验证镜像存在

```bash
docker images harbor.testops.local/testops/zentao
```

---

## 第六步：部署禅道到 Kubernetes

### 6.1 部署前检查清单

| 检查项 | 验证命令 | 预期结果 |
|--------|---------|---------|
| kubectl 连接正常 | `kubectl cluster-info` | 输出集群信息 |
| Namespace 不存在 | `kubectl get ns zentao` | NotFound（脚本自动创建） |
| StorageClass 可用 | `kubectl get sc` | 存在 nfs-client 或自定义 SC |
| Ingress Controller 已安装 | `kubectl get pods -n ingress-nginx` | Running |
| MySQL 可达 | `mysql -h <host> -u zentao -p -e "SELECT 1"` | 输出 1 |

### 6.2 一键部署

```bash
cd D:\testops_platfrom_deploy\modules\zentao_deploy
python main.py deploy
```

此命令按顺序创建以下 K8s 资源：

```
[1/6] Namespace → zentao
[2/6] Secret → mysql-user / mysql-password / mysql-database
[3/6] PVC → zentao-data-pvc (20Gi) + zentao-config-pvc (1Gi)
[4/6] ConfigMap → php 配置参数
[5/6] Deployment → 禅道容器（imagePullPolicy: IfNotPresent）
       └── Service (ClusterIP:8080)
       └── Ingress (zentao.testops.local → 禅道)
[6/6] 等待 Pod Ready（最多 180 秒）
```

### 6.3 部署后验证

```bash
# 查看 Pod 状态
kubectl get pods -n zentao

# 查看 Service / Ingress
kubectl get svc,ingress -n zentao

# 查看 Pod 日志
kubectl logs -n zentao -l app=zentao --tail=50
```

### 6.4 配置本地 hosts 解析（如未配置 DNS）

```bash
# 编辑 hosts 文件
# Windows: C:\Windows\System32\drivers\etc\hosts
# Linux:   /etc/hosts

# 添加一行
<任意节点IP>  zentao.testops.local
```

---

## 第七步：部署后健康验证

### 7.1 一键健康检查

```bash
python main.py check
```

输出示例：
```
==================================================
  禅道部署后健康检查
==================================================
[1/5] K8s Pod 状态...   PASS  1/1 Running
[2/5] Web 连通性...      PASS  HTTP 302
[3/5] 外部 MySQL 连通性.. PASS  192.168.0.100:3306
[4/5] PVC 绑定状态...    PASS  zentao-data-pvc: Bound
                         PASS  zentao-config-pvc: Bound
[5/5] 容器内磁盘空间...  PASS
==================================================
  总计 5/5 通过
==================================================
```

### 7.2 手动验证

```bash
# 1. Pod 状态
kubectl get pods -n zentao -o wide

# 2. Web 可访问性
curl -I http://zentao.testops.local/

# 3. 进入容器检查
kubectl exec -n zentao -it deploy/zentao -- bash
# 容器内检查:
php -v                          # PHP 8.1.27
httpd -v                        # Apache 2.4.62
cat /var/www/zentaopms/config/my.php  # 配置正确
df -h /var/www/zentaopms/www/data      # PVC 挂载正常

# 4. MySQL 连接测试
kubectl exec -n zentao deploy/zentao -- php -r "
  \$conn = new PDO('mysql:host=192.168.0.100;port=3306;charset=utf8mb4','zentao','password');
  echo 'MySQL OK';
"
```

---

## 第八步：禅道初始化配置

### 8.1 浏览器访问

裸机：`http://192.168.0.102:8080/`  
容器：`http://192.168.0.102:8080/`

### 8.2 默认管理员

部署脚本已自动完成数据库初始化，无需手动安装向导。直接登录：

```
账号: admin
密码: 123456
```

### 8.3 手动重装（如需）

```bash
# 安装器保留为 .tmp，需要时重命名
cp /var/www/zentaopms/www/install.php.tmp /var/www/zentaopms/www/install.php
# 访问 http://192.168.0.102:8080/install.php
# 完成后删除 install.php（安全要求）
rm -f /var/www/zentaopms/www/install.php
```

---

## 一键部署 / 一键销毁

### 裸机一键部署

```bash
bash build_php.sh
```

### Docker 镜像构建 + 启动

```bash
bash build.sh 21.2 && docker rm -f zentao; docker run -d --name zentao -p 8080:8080 \
  -e ZT_MYSQL_HOST=192.168.0.102 -e ZT_MYSQL_PORT=3306 \
  -e ZT_MYSQL_USER=root -e ZT_MYSQL_PASSWORD='Kd9$prL7sQ2!vzB4' \
  -e ZT_MYSQL_DB=zendao harbor.testops.local/testops/zentao:21.2
```

### 一键清理

```bash
bash clean_php.sh     # 全部清理
```

---

## CLI 命令参考

### 部署脚本

| 命令 | 说明 |
|------|------|
| `bash build_php.sh` | 裸机部署：编译 PHP/Apache + 初始化 DB + 启动 |
| `bash build.sh [版本] [push]` | Docker 镜像构建（可选推送 Harbor） |
| `bash clean_php.sh` | 全部清理 |
| `bash clean_php.sh -z` | 仅清理禅道源码 |
| `bash clean_php.sh -p` | 仅清理 PHP/Apache 编译产物 |

### Docker 容器

| 命令 | 说明 |
|------|------|
| `docker run -d --name zentao -p 8080:8080 -e ...` | 启动容器 |
| `docker logs -f zentao` | 查看日志 |
| `docker exec -it zentao bash` | 进入容器 |
| `docker restart zentao` | 重启 |
| `docker rm -f zentao` | 停止并删除 |

### MySQL

| 命令 | 说明 |
|------|------|
| `bash install_mysql.sh` | 安装 MySQL 8.0.35 |
| `bash uninstall_mysql.sh` | 卸载 MySQL |
| `systemctl start\|stop\|restart\|status mysqld` | MySQL 服务管理 |

---

## 插件管理

### 支持方式

| 方式 | 说明 | 网络要求 |
|------|------|---------|
| **在线安装** | 禅道应用市场直接下载安装 | 需要容器能访问互联网 |
| **离线安装** | 手动上传 .zip 插件包到 PVC，通过 CLI 安装 | 无需外网 |

### 在线安装

```bash
# 列出可用插件（需容器内执行）
kubectl exec -n zentao deploy/zentao -- \
  php /var/www/zentaopms/bin/ztcli.php plugin-list

# 安装指定插件
python main.py plugin install <插件名称>
# 示例: python main.py plugin install zentaobiz

# 安装后在禅道后台 → 插件管理 → 激活插件
```

### 离线安装（推荐生产环境）

```bash
# 1. 下载插件 .zip 包到本地
# 2. 上传到 PVC 持久化目录
kubectl cp <plugin>.zip \
  zentao/$(kubectl get pod -n zentao -l app=zentao -o jsonpath='{.items[0].metadata.name}'):/var/www/zentaopms/tmp/

# 3. 执行安装
python main.py plugin install-offline <plugin>.zip

# 4. 激活插件
# 登录禅道 → 后台管理 → 插件管理 → 找到插件 → 激活
```

### 插件持久化保证

插件安装到 `/var/www/zentaopms/module/<plugin_name>/` 和 `/var/www/zentaopms/extension/custom/`，这些目录挂载了 PVC `zentao-data-pvc`，容器重建后插件数据不丢失。

### 插件目录结构

```
zentao-data-pvc (PVC)
├── module/          # 在线安装的官方插件
│   ├── zentaobiz/
│   └── ...
├── extension/
│   └── custom/      # 离线安装的自定义扩展
└── config/ext/      # 插件配置文件（zentao-config-pvc）
```

---

## TestOps 集成：OpenAPI 测试同步

### 禅道 OpenAPI 接口

禅道提供 REST API 接口，支持从 CI/CD 流水线自动同步测试结果：

| 接口 | 用途 | 路径 |
|------|------|------|
| 创建缺陷 | 自动化测试失败自动提单 | `POST /api.php/v1/bugs` |
| 创建测试用例 | 同步测试用例到禅道 | `POST /api.php/v1/testcases` |
| 更新缺陷状态 | 修复后自动关闭 Bug | `PUT /api.php/v1/bugs/{id}` |
| 获取产品列表 | 查询产品 ID | `GET /api.php/v1/products` |

### API Token 配置

```bash
# 禅道后台 → 二次开发 → API → 创建 API Key
# 将 Token 设为环境变量
export ZENTAO_API_TOKEN="your-api-token-here"
```

### 流水线调用示例

```python
from modules.zentao.verify.testcase_sync import ZentaoAPIClient

client = ZentaoAPIClient("http://zentao.testops.local", api_token)
client.create_bug(
    product_id=1,
    title="[CI] 自动化测试发现缺陷 — 登录超时",
    severity=3,
    steps="1. 访问登录页\n2. 输入凭证\n3. 响应超过5秒"
)
```

---

## 外部组件部署清单

禅道部署依赖以下外部组件，需提前准备：

| 序号 | 组件 | 版本 | 部署位置 | 准备步骤 |
|------|------|------|---------|---------|
| 1 | **MySQL** | 8.0.35 | 独立服务器 192.168.0.100 | 见第二步 |
| 2 | **Harbor** | ≥ v2.8 | 独立服务器 | Docker Compose 部署 |
| 3 | **K8s 集群** | ≥ v1.21 | 已有集群 | kubectl 配置 |
| 4 | **Ingress Controller** | nginx-ingress | K8s 集群 | `kubectl apply -f` 部署 |
| 5 | **StorageClass** | NFS / Ceph | K8s 集群 | 提供者配置 |
| 6 | **编译服务器** | CentOS Stream 9 | 192.168.0.100 | 见第三步 |

### Harbor 部署（参考）

```bash
# 在 Harbor 服务器上执行
wget https://github.com/goharbor/harbor/releases/download/v2.9.0/harbor-offline-installer-v2.9.0.tgz
tar -xzf harbor-offline-installer-v2.9.0.tgz
cd harbor
cp harbor.yml.tmpl harbor.yml
# 编辑 harbor.yml: hostname / harbor_admin_password
./install.sh
```

### Ingress Controller 部署

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.0/deploy/static/provider/cloud/deploy.yaml
kubectl get pods -n ingress-nginx
```

---

## 硬性约束与规范

| 约束 | 规则 |
|------|------|
| 版本 | 仅禅道开源版，禁止企业版/IPD版 |
| 镜像来源 | 禁止使用现成 Docker 镜像，必须 CentOS Stream 9 源码编译 |
| 编译工具 | 仅 yum 源基础命令（gcc/make/autoconf 等），不引入小众第三方工具 |
| MySQL | 外部物理机独立部署，K8s 内不运行 MySQL 容器 |
| 持久化 | 仅 PVC 挂载 `/data` 目录（附件+插件），源码/日志/tmp 不持久化 |
| 敏感信息 | 密码使用 K8s Secret，非密码配置使用 ConfigMap |
| 容器权限 | 非 root 用户（www:www）运行 |

---

## 数据持久化官方标准

| 容器路径 | 内容 | 持久化 | 原因 |
|----------|------|--------|------|
| `/var/www/zentaopms/www/data/upload/` | 测试截图、文档、上传附件 | ✅ PVC | 用户数据不可丢失 |
| `/var/www/zentaopms/config/ext/` | 离线插件 | ✅ PVC | 插件持久保留 |
| `/var/www/zentaopms/extension/custom/` | 自定义扩展 | ✅ PVC | 二次开发扩展 |
| `/var/www/zentaopms/` | 禅道源码 | ❌ | 镜像内置，升级替换镜像 |
| `/var/www/zentaopms/tmp/` | 临时文件 | ❌ emptyDir | 临时存储 |
| 日志 | 运行日志 | ❌ stdout | 外部日志系统采集 |

---

## Jenkins CI/CD 流水线

### 流水线流程

```
Git Push → Jenkins Trigger → SonarQube Scan → Maven Build Jar
→ Docker Build Image → Push Harbor → K8s Deploy → 冒烟测试
```

### Jenkins 必要插件

| 插件 | 用途 |
|------|------|
| Pipeline | 流水线核心引擎 |
| Git Plugin | 源码拉取 |
| Docker Pipeline | 镜像构建推送 |
| SonarQube Scanner | 代码质量扫描 |
| Kubernetes CLI | kubectl 命令 |
| Credentials Binding | 凭证管理 |

### Jenkinsfile

完整流水线脚本位于 `modules/java_app_cicd/jenkins/Jenkinsfile`，包含 6 个 Stage：

| Stage | 操作 |
|-------|------|
| Checkout | Git 拉取源码 |
| SonarQube Scan | 静态代码质量分析 |
| Quality Gate | 质量门禁检查 |
| Maven Build | 构建 Jar 包 |
| Docker Build & Push | 构建镜像 + 推送 Harbor |
| Deploy to K8s | kubectl 部署到测试环境 |

---

## 运维配套方案

### 定时备份 CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: zentao-backup
  namespace: zentao
spec:
  schedule: "0 2 * * *"       # 每天凌晨 2:00
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: mysql:8.0.35
            command:
            - /bin/sh
            - -c
            - |
              DATE=$(date +%Y%m%d-%H%M)
              mysqldump -h <mysql-host> -u zentao -p${MYSQL_PASSWORD} \
                --all-databases --single-transaction > /backup/zentao-${DATE}.sql
              find /backup -name "*.sql" -mtime +7 -delete
```

### 版本升级步骤

```bash
# 1. 备份数据库
mysqldump -h <mysql-host> -u zentao -p --all-databases > backup-$(date +%Y%m%d).sql

# 2. 构建新版本镜像
python main.py build --version 22.0 --push

# 3. 滚动升级
python main.py upgrade --version 22.0
```

### 故障恢复

```bash
# 从备份恢复数据库
mysql -h <mysql-host> -u zentao -p zentao < backup-20260727.sql

# 重新部署禅道
python main.py destroy --force
python main.py deploy
```

---

## 远期扩展规划

> 状态：方案设计阶段，暂不编码。详见 `docs/future_integrate/` 目录。

| 扩展项 | 说明 | 状态 |
|--------|------|------|
| **MaxKey SSO** | OIDC 统一认证单点登录 | 方案设计中 |
| **权限分组** | 开发/测试/PM 多角色权限 | 方案设计中 |
| **审批流程** | 迭代/上线/缺陷流转审批（需二次开发） | 方案设计中 |
| **MinIO 迁移** | 附件从 PVC 迁移至独立 MinIO 集群 | 方案设计中 |
| **OpenAPI 集成** | CI/CD 流水线自动提单/更新缺陷 | 预留接口 |
