# YUM 仓库配置

## 环境信息

| 项目 | 值 |
|------|-----|
| 操作系统 | CentOS Stream 9 |
| 内核版本 | 5.14.0-725.el9.x86_64 |
| 包管理器 | yum (基于 DNF) |

---

## 当前已配置的 YUM 仓库

```
repo id         repo name
base            CentOS-9 - Base - mirrors.aliyun.com
AppStream       CentOS-9 - AppStream - mirrors.aliyun.com
centosplus      CentOS-9 - Plus - mirrors.aliyun.com    (禁用)
PowerTools      CentOS-9 - PowerTools - mirrors.aliyun.com (禁用)
epel            Extra Packages for Enterprise Linux 9 - x86_64
tuna-baseos     TUNA CentOS Stream 9 - BaseOS
```

---

## 仓库配置文件

### 文件列表

```
/etc/yum.repos.d/
├── centos.repo              # Base / AppStream / centosplus / PowerTools (阿里云镜像)
├── centos.repo.backup        # 旧配置备份
├── epel.repo                 # EPEL 官方源
├── epel-testing.repo         # EPEL 测试源 (禁用)
├── epel-cisco-openh264.repo  # EPEL Cisco OpenH264
├── tuna.repo                 # 清华 TUNA 镜像 (备用)
├── vscode.repo               # Visual Studio Code
├── google-chrome.repo        # Google Chrome
└── fedora-ayatana.repo       # Fedora Ayatana
```

### /etc/yum.repos.d/centos.repo

```ini
[base]
name=CentOS-$releasever - Base - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/BaseOS/$basearch/os/
        http://mirrors.aliyuncs.com/centos-stream/$stream/BaseOS/$basearch/os/
        http://mirrors.cloud.aliyuncs.com/centos-stream/$stream/BaseOS/$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos-stream/RPM-GPG-KEY-CentOS-Official

[AppStream]
name=CentOS-$releasever - AppStream - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/AppStream/$basearch/os/
        http://mirrors.aliyuncs.com/centos-stream/$stream/AppStream/$basearch/os/
        http://mirrors.cloud.aliyuncs.com/centos-stream/$stream/AppStream/$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos-stream/RPM-GPG-KEY-CentOS-Official

[centosplus]
name=CentOS-$releasever - Plus - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/centosplus/$basearch/os/
        http://mirrors.aliyuncs.com/centos-stream/$stream/centosplus/$basearch/os/
        http://mirrors.cloud.aliyuncs.com/centos-stream/$stream/centosplus/$basearch/os/
gpgcheck=1
enabled=0

[PowerTools]
name=CentOS-$releasever - PowerTools - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/PowerTools/$basearch/os/
        http://mirrors.aliyuncs.com/centos-stream/$stream/PowerTools/$basearch/os/
        http://mirrors.cloud.aliyuncs.com/centos-stream/$stream/PowerTools/$basearch/os/
gpgcheck=1
enabled=0
```

### /etc/yum.repos.d/epel.repo

```ini
[epel]
name=Extra Packages for Enterprise Linux 9 - $basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=$basearch&infra=$infra&content=$contentdir
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9
```

### /etc/yum.repos.d/tuna.repo（备用）

```ini
[tuna-baseos]
name=TUNA CentOS Stream 9 - BaseOS
baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos-stream/9-stream/BaseOS/x86_64/os/
enabled=1
gpgcheck=0
```

---

## YUM 配置步骤

### 1. 备份原有配置

```bash
sudo cp /etc/yum.repos.d/centos.repo /etc/yum.repos.d/centos.repo.backup
```

### 2. 配置阿里云镜像源

```bash
sudo tee /etc/yum.repos.d/centos.repo << 'EOF'
[base]
name=CentOS-$releasever - Base - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/BaseOS/$basearch/os/
        http://mirrors.aliyuncs.com/centos-stream/$stream/BaseOS/$basearch/os/
        http://mirrors.cloud.aliyuncs.com/centos-stream/$stream/BaseOS/$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos-stream/RPM-GPG-KEY-CentOS-Official

[AppStream]
name=CentOS-$releasever - AppStream - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/AppStream/$basearch/os/
        http://mirrors.aliyuncs.com/centos-stream/$stream/AppStream/$basearch/os/
        http://mirrors.cloud.aliyuncs.com/centos-stream/$stream/AppStream/$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos-stream/RPM-GPG-KEY-CentOS-Official

[centosplus]
name=CentOS-$releasever - Plus - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/centosplus/$basearch/os/
gpgcheck=1
enabled=0
gpgkey=https://mirrors.aliyun.com/centos-stream/RPM-GPG-KEY-CentOS-Official

[PowerTools]
name=CentOS-$releasever - PowerTools - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/PowerTools/$basearch/os/
gpgcheck=1
enabled=0
gpgkey=https://mirrors.aliyun.com/centos-stream/RPM-GPG-KEY-CentOS-Official
EOF
```

### 3. 配置 EPEL 源

```bash
sudo yum install -y epel-release
```

### 4. 添加清华 TUNA 备用源

```bash
sudo tee /etc/yum.repos.d/tuna.repo << 'EOF'
[tuna-baseos]
name=TUNA CentOS Stream 9 - BaseOS
baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos-stream/9-stream/BaseOS/x86_64/os/
enabled=1
gpgcheck=0
EOF
```

### 5. 重建缓存

```bash
sudo yum clean all
sudo yum makecache
```

---

## 验证 YUM 配置

### 检查仓库列表

```bash
yum repolist
```

预期输出：
```
repo id         repo name
base            CentOS-9 - Base - mirrors.aliyun.com
AppStream       CentOS-9 - AppStream - mirrors.aliyun.com
epel            Extra Packages for Enterprise Linux 9 - x86_64
tuna-baseos     TUNA CentOS Stream 9 - BaseOS
```

### 检查可用更新

```bash
yum check-update
```

### 搜索包

```bash
yum search containerd
yum search kubeadm
```

### 安装测试

```bash
sudo yum install -y yum-utils
```

---

## 常用 YUM 操作命令

### 包管理

```bash
sudo yum install -y <package>       # 安装
sudo yum remove -y <package>        # 卸载
yum info <package>                  # 查看信息
yum list installed | grep <kw>      # 已安装
yum list available | grep <kw>      # 可安装
```

### 仓库管理

```bash
yum repolist all                                             # 全部仓库（含禁用）
yum --enablerepo=<repo> install <package>                    # 指定仓库安装
sudo yum-config-manager --disable <repo>                     # 禁用仓库
sudo yum-config-manager --enable <repo>                      # 启用仓库
sudo yum-config-manager --add-repo <url>                     # 添加新仓库
```

---

## K8s 部署所需的 YUM 仓库

以下操作由 `stage2` 和 `stage3` 通过 SSH 在**远程目标节点**上自动执行：

### Stage 2 — containerd 安装（Docker CE 仓库）

```bash
# 安装 yum-utils
sudo yum install -y yum-utils

# 添加 Docker CE 仓库
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# 安装 containerd
sudo yum install -y containerd.io
```

### Stage 3 — kubeadm/kubectl/kubelet 安装（Kubernetes 仓库）

```bash
# 添加阿里云 K8s 仓库
sudo tee /etc/yum.repos.d/kubernetes.repo << 'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=0
EOF

# 安装 K8s 组件（指定版本）
sudo yum install -y kubeadm-<version> kubectl-<version> kubelet-<version> --disableexcludes=kubernetes
```

> **注意**: 如果目标节点是 CentOS Stream 9，Kubernetes YUM 仓库 URL 中的 `el7` 可能需要改为 `el9`。

---

## 故障排查

### yum 命令卡住/超时

```bash
# 1. 检查是否有多个 yum 进程
ps aux | grep -E 'yum|dnf' | grep -v grep

# 2. 杀掉卡住的进程
sudo kill -9 <pid>

# 3. 清理缓存重试
sudo yum clean all
sudo yum makecache
```

### 镜像源不可达

```bash
# 测试连通性
curl -sI --connect-timeout 5 https://mirrors.aliyun.com/centos-stream/

# 临时仅用 base 仓库测试
yum --disablerepo="*" --enablerepo="base,AppStream" repolist
```

### RPM 数据库锁定

```bash
# 检查锁
ls -la /var/run/yum.pid
fuser /var/lib/rpm/.dbenv.lock

# 确认无 yum 进程后删除锁
sudo rm -f /var/run/yum.pid
```

### GPG Key 缺失

```bash
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9
```

---

## 镜像源地址参考

| 镜像源 | BaseOS URL | AppStream URL |
|--------|-----------|---------------|
| 阿里云 | `https://mirrors.aliyun.com/centos-stream/9-stream/BaseOS/x86_64/os/` | `https://mirrors.aliyun.com/centos-stream/9-stream/AppStream/x86_64/os/` |
| 阿里云内网 | `http://mirrors.cloud.aliyuncs.com/centos-stream/...` | 同上 |
| 清华 TUNA | `https://mirrors.tuna.tsinghua.edu.cn/centos-stream/9-stream/BaseOS/x86_64/os/` | — |
| 中科大 USTC | `https://mirrors.ustc.edu.cn/centos-stream/9-stream/BaseOS/x86_64/os/` | — |
| 官方 | `https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/` | — |
