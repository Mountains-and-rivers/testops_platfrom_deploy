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

### 2.1 安装 MySQL 8.0

```bash
# SSH 登录 MySQL 服务器，以 root 执行
ssh root@192.168.0.100

# 安装 MySQL 8.0
dnf install -y mysql-server
systemctl enable mysqld --now

# 获取临时密码
grep 'temporary password' /var/log/mysqld.log

# 安全初始化
mysql_secure_installation
```

### 2.2 创建禅道数据库和用户

```sql
-- 登录 MySQL
mysql -u root -p

-- 创建数据库（utf8mb4 字符集）
CREATE DATABASE IF NOT EXISTS zentao
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_general_ci;

-- 创建用户并授权
CREATE USER 'zentao'@'%' IDENTIFIED BY 'YourMysqlPassword456!';
GRANT ALL PRIVILEGES ON zentao.* TO 'zentao'@'%';
FLUSH PRIVILEGES;

-- 验证字符集
SHOW VARIABLES LIKE 'character_set%';
-- 预期结果:
-- character_set_server   | utf8mb4
-- character_set_database | utf8mb4
```

### 2.3 配置远程访问

```bash
# 确保 MySQL 监听所有网络接口
grep bind-address /etc/my.cnf.d/mysql-server.cnf
# 如为 127.0.0.1，修改为 0.0.0.0 或注释掉

# 重启 MySQL
systemctl restart mysqld

# 测试远程连接
mysql -h 192.168.0.100 -u zentao -p -e "SELECT 1"
```

### 2.4 MySQL 配置优化（生产环境推荐）

```ini
# /etc/my.cnf.d/zenta.cnf
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
max_allowed_packet = 64M
innodb_buffer_pool_size = 2G
innodb_file_per_table = ON
```

---

## 第三步：编译服务器环境准备

### 3.1 执行编译环境初始化

```bash
# 将 build_support.sh 上传到编译服务器
scp modules/zentao/build/build_support.sh root@192.168.0.100:/opt/

# SSH 登录编译服务器，执行初始化
ssh root@192.168.0.100
bash /opt/build_support.sh
```

该脚本自动完成：
- 安装 23 个编译依赖包（gcc/make/autoconf/libxml2-devel/libpng-devel 等）
- 验证 gcc/make/wget/git/docker 可用性
- 启动 Docker 服务

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

### 4.1 拉取禅道开源版源码

```bash
cd D:\testops_platfrom_deploy\modules\zentao_deploy

# 自动从 GitHub 拉取（失败自动切换 Gitee 镜像）
python main.py build --version 21.2
```

此命令的内部执行流程：
1. Git clone `https://github.com/easysoft/zentaopms` → `modules/zentao/build/source/`
2. Checkout 到 tag `21.2`
3. 清理 `.git` 目录（减小镜像体积）

### 4.2 Dockerfile 构建流程

```
Stage 1: centos:stream9 (编译阶段)
  ├── 安装 23 个编译依赖
  ├── 下载 Apache httpd 2.4.62 源码 → ./configure → make → make install → /opt/httpd
  ├── 下载 PHP 8.1.27 源码 → ./configure（18个扩展）→ make → make install → /opt/php
  └── strip 二进制 + 清理源码

Stage 2: centos:stream9 (运行阶段)
  ├── 安装运行期依赖（仅必要的 .so 库）
  ├── COPY --from=builder /opt/php + /opt/httpd
  ├── COPY source/ → /var/www/zentaopms/
  ├── 创建 www 用户 / 配置 Apache + PHP
  ├── docker-entrypoint.sh（首次启动生成 my.php）
  └── HEALTHCHECK curl localhost:8080
```

### 4.3 构建镜像（本地或远程编译服务器）

```bash
# 方式 1：本地构建（工作站有 Docker 且为 Linux amd64）
python main.py build --version 21.2

# 方式 2：远程编译服务器构建
ssh root@192.168.0.100 "cd /opt/build && python3 build_image.py --version 21.2"
```

### 4.4 构建常见报错排查

| 错误 | 原因 | 解决 |
|------|------|------|
| `configure: error: libxml2 not found` | 缺少 libxml2-devel | `dnf install -y libxml2-devel` |
| `configure: error: libzip >= 1.3.1 not found` | libzip 版本低 | `dnf install -y libzip-devel` |
| `configure: error: freetype-config not found` | 缺少 freetype-devel | `dnf install -y freetype-devel` |
| `oniguruma not found` | 缺少 oniguruma-devel | `dnf install -y oniguruma-devel` |
| `apxs: command not found` | 缺少 httpd-devel | `dnf install -y httpd-devel` |
| Docker daemon not running | Docker 未启动 | `systemctl start docker` |
| `git clone` 超时 | GitHub 不可达 | 自动切换 Gitee 镜像 |

---

## 第五步：推送镜像到 Harbor 私有仓库

### 5.1 登录 Harbor

```bash
# 在工作站执行
docker login harbor.testops.local -u admin -p YourHarborPassword123!
```

### 5.2 构建并推送

```bash
# 构建 + 本地验证 + 推送一步完成
python main.py build --version 21.2 --push
```

内部验证步骤：
1. `docker run -d --name zentao-verify -p 18080:8080` 启动验证容器
2. `curl http://localhost:18080/` 检查 HTTP 响应
3. 验证通过后 `docker rm -f zentao-verify`
4. `docker push` 推送到 Harbor

### 5.3 验证 Harbor 中镜像存在

```bash
curl -u admin:YourHarborPassword123! \
  https://harbor.testops.local/api/v2.0/projects/testops/repositories/zentao/artifacts
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

```
http://zentao.testops.local/
```

首次访问自动跳转安装向导 `install.php`。

### 8.2 安装向导步骤

1. **欢迎页** → 点击"开始安装"
2. **环境检查** → 确认所有检查项通过（PHP 版本 / 扩展 / 目录权限）
3. **数据库配置**
   - 数据库服务器：`192.168.0.100`（外部 MySQL 地址）
   - 数据库端口：`3306`
   - 数据库用户：`zentao`
   - 数据库密码：`YourMysqlPassword456!`
   - 数据库名：`zentao`
4. **设置管理员** → 填写管理员账号/密码
5. **完成安装** → 登录禅道

### 8.3 安装后基础配置

```bash
# 公司信息
登录 → 后台管理 → 公司 → 编辑公司信息

# 创建用户
后台管理 → 组织 → 用户 → 添加用户

# 创建第一个项目
项目 → 添加项目 → 填写项目名称/负责人/起止日期
```

---

## 一键部署 / 一键销毁

### 完整链路一键部署

```bash
# 从源码到部署一气呵成（构建 + 推送 + 部署 + 验证）
python main.py full-deploy --version 21.2
```

内部执行流程：
```
1. 环境预检（磁盘/网络/Docker/必要命令）
2. Git 拉取禅道 v21.2 源码
3. Docker 多阶段编译（约 5-15 分钟）
4. 本地验证容器启动
5. 推送镜像到 Harbor
6. K8s 部署 Namespace/Secret/PVC/Deployment/Service/Ingress
7. 等待 Pod 就绪
8. Web/MySQL/PVC 健康检查
9. 输出访问地址
```

### 一键销毁

```bash
# 删除 K8s 资源（保留 PVC 数据）
python main.py destroy --force

# 完全清理（包括 PVC 数据永久删除）
python main.py destroy --delete-pvc --force
```

---

## CLI 命令参考

| 命令 | 说明 |
|------|------|
| `python main.py build` | 拉取源码 + 构建镜像 |
| `python main.py build --push` | 构建 + 推送到 Harbor |
| `python main.py deploy` | 部署禅道到 K8s |
| `python main.py destroy --force` | 一键销毁 |
| `python main.py destroy --delete-pvc --force` | 销毁 + 删除数据 |
| `python main.py upgrade --version 22.0` | 滚动升级 |
| `python main.py check` | 健康检查 |
| `python main.py plugin install <name>` | 在线安装插件 |
| `python main.py plugin install-offline <zip>` | 离线安装插件 |
| `python main.py plugin list` | 列出已安装插件 |
| `python main.py full-deploy` | 完整链路（构建→推送→部署→验证） |

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
