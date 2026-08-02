# YUM 仓库配置说明

## 环境信息

| 项目 | 值 |
|------|-----|
| 操作系统 | CentOS Stream 9 |
| 内核版本 | 5.14.0-725.el9.x86_64 |
| 包管理器 | yum (基于 DNF) |
| 架构 | x86_64 |

---

## 仓库文件清单

```
/etc/yum.repos.d/
├── centos.repo              # 基础仓库 (BaseOS + AppStream + CRB)
├── centos-addons.repo        # 附加仓库 (HA / NFV / RT / Extras)
├── docker-ce.repo            # Docker CE 仓库 (containerd)
└── kubernetes.repo           # Kubernetes 仓库 (kubeadm/kubectl/kubelet)
```

---

## 版本号说明

### RPM 包版本号拆解

```
kubeadm-1.32.13-150500.1.1.x86_64.rpm
        │       │            │
        │       │            └── 架构 (x86_64 / aarch64)
        │       └── RPM 构建号 (openSUSE Build Service)
        └── K8s 语义版本
```

- **K8s 版本**：`X.Y.Z` 格式（如 `1.32.13`），与容器镜像 tag 严格一致
- **RPM 构建号**：`150500.1.1`，由 OBS 自动生成，每次 rebuild 递增，不影响 K8s 功能
- **架构**：`x86_64`，当前部署目标

### 版本一致性

```
software_version.yaml  kubernetes.default = "1.32.13"
        │
        ├── Stage 3: rpm -Uvh kubeadm-1.32.13-*.rpm
        │   安装后 kubeadm version → v1.32.13
        │
        └── Stage 4: kubeadm config images list --config=...
             输出 registry.k8s.io/kube-apiserver:v1.32.13
             输出 registry.k8s.io/pause:3.10
             sandbox guard 追加 pause:3.10.1
```

**所有版本以 `software_version.yaml` 为准，kubeadm 版本决定镜像版本，不会错位。**

### 版本更新策略

| 方式 | 行为 |
|------|------|
| 本地 RPM 存在 | 锁定本地 RPM 版本，不联网 |
| 本地 RPM 不存在 | 动态获取仓库最新版本 → 安装 → 镜像回写 images/，下次锁定 |

---

## 镜像版本

| 组件 | 版本 | 来源 |
|------|------|------|
| Kubernetes | `v1.32.13` | `kubeadm config images list` |
| pause | `3.10.1` | kubeadm 写入 containerd 的实际版本 |
| Calico | `v3.29.1` | `cluster_info.yaml` cni.calico.version |
| etcd | `3.5.16-0` | `kubeadm config images list` |
| CoreDNS | `v1.11.3` | `kubeadm config images list` |
```

| 文件 | 来源 | 写入阶段 | 说明 |
|------|------|----------|------|
| `centos.repo` | 阿里云镜像 | Stage 1 (sys_init) | 替换系统默认，加速包下载 |
| `docker-ce.repo` | 阿里云镜像 | Stage 2 (containerd) | 安装 containerd.io |
| `centos-addons.repo` | 系统默认 | 未修改 | Extras / HA / NFV 等可选仓库 |

---

## centos.repo — 基础仓库（阿里云镜像）

### 写入方式

Stage 1 通过 SSH heredoc 直接写入，不使用模板文件，避免路径依赖问题：

```bash
cat > /etc/yum.repos.d/centos.repo << 'YUM_EOF'
[baseos]
name=CentOS Stream $releasever - BaseOS - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/BaseOS/$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[appstream]
name=CentOS Stream $releasever - AppStream - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-stream/$stream/AppStream/$basearch/os/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
YUM_EOF
```

### 关键设计

- `<< 'YUM_EOF'` 单引号定界符 → shell 不展开 `$releasever` / `$stream` / `$basearch`
- DNF 运行时自动解析：`$stream` → `9-stream`，`$basearch` → `x86_64`
- 只包含 `[baseos]` + `[appstream]` 两个核心仓库，K8s 部署必需的包都在其中
- 原文件备份为 `centos.repo.k8s_bak`，回滚时恢复
- 写入后执行 `yum clean all && yum makecache` 重建缓存

### 仓库地址

| 仓库 ID | URL |
|---------|-----|
| `baseos` | `https://mirrors.aliyun.com/centos-stream/9-stream/BaseOS/x86_64/os/` |
| `appstream` | `https://mirrors.aliyun.com/centos-stream/9-stream/AppStream/x86_64/os/` |

### 默认配置（已备份）

系统原始的 `centos.repo` 使用 `metalink` 指向 CentOS 官方镜像：

```ini
[baseos]
name=CentOS Stream $releasever - BaseOS
metalink=https://mirrors.centos.org/metalink?repo=centos-baseos-$stream&arch=$basearch&protocol=https,http
```

`metalink` 会根据客户端地理位置自动选择最近的镜像，但在中国大陆可能较慢。K8s 部署平台将其替换为阿里云 `baseurl` 直接加速。

---

## docker-ce.repo — Docker CE 仓库（阿里云镜像）

### 写入方式

Stage 2 通过 `yum-config-manager --add-repo` 添加，然后 `sed` 替换为阿里云地址：

```bash
yum-config-manager --add-repo \
  https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

sed -i 's|https://download.docker.com|https://mirrors.aliyun.com/docker-ce|g' \
  /etc/yum.repos.d/docker-ce.repo
```

### 仓库段

| 仓库 ID | 状态 | 用途 |
|---------|------|------|
| `docker-ce-stable` | **enabled** | containerd.io 稳定版 |
| `docker-ce-stable-debuginfo` | disabled | 调试符号 |
| `docker-ce-stable-source` | disabled | 源码包 |
| `docker-ce-test` | disabled | 测试版 |
| `docker-ce-nightly` | disabled | 每日构建版 |

### 可用 containerd 版本

```
containerd.io.x86_64    2.2.6-1.el9    docker-ce-stable
containerd.io.x86_64    2.3.3-1.el9    docker-ce-stable
```

> **注意**: containerd 1.7.x 系列在 CentOS Stream 9 的 Docker CE 仓库中不可用，需使用 2.x 版本。

---

## centos-addons.repo — 附加仓库（系统默认，未修改）

包含 CentOS Stream 9 的可选仓库，均默认禁用：

| 仓库 ID | 用途 | 默认状态 |
|---------|------|----------|
| `highavailability` | 高可用组件 (pacemaker 等) | disabled |
| `nfv` | 网络功能虚拟化 | disabled |
| `rt` | 实时内核 | disabled |
| `resilientstorage` | 弹性存储 (glusterfs 等) | disabled |
| `extras-common` | EPEL 兼容包 | **enabled** |

---

## YUM 配置流程（自动化）

```
Stage 0: 环境预检
    └── 不涉及 yum

Stage 1: 系统初始化
    └── Step 7.5: 配置 YUM 源
        ├── mv centos.repo → centos.repo.k8s_bak    (备份)
        ├── cat > centos.repo << 'YUM_EOF'           (写入阿里云源)
        ├── yum clean all                            (清缓存)
        └── yum makecache                            (重建缓存)

Stage 2: 容器运行时安装
    └── Step 0: 清理残留 kubernetes.repo
    └── Step 1: 添加 docker-ce.repo (阿里云)
    └── yum install -y containerd.io

Stage 3: K8s 组件安装
    └── 写入 /etc/yum.repos.d/kubernetes.repo
    └── yum install -y kubeadm kubectl kubelet
```

---

## 故障排查

### 查看当前仓库列表

```bash
yum repolist
```

正常输出：
```
repo id            repo name
appstream          CentOS Stream 9 - AppStream - mirrors.aliyun.com
baseos             CentOS Stream 9 - BaseOS - mirrors.aliyun.com
docker-ce-stable   Docker CE Stable - x86_64
extras-common      CentOS Stream 9 - Extras packages
```

### 测试镜像连通性

```bash
curl -sI --connect-timeout 5 https://mirrors.aliyun.com/centos-stream/
```

### yum 命令卡住

```bash
# 查看是否有残留 yum 进程
ps aux | grep -E 'yum|dnf' | grep -v grep

# 杀掉卡住的进程
kill -9 <pid>

# 清理锁文件
rm -f /var/run/yum.pid

# 重建缓存
yum clean all && yum makecache
```

### 恢复原始仓库

```bash
mv /etc/yum.repos.d/centos.repo.k8s_bak /etc/yum.repos.d/centos.repo
yum clean all && yum makecache
```

### 搜索可用包

```bash
yum search containerd
yum search kubeadm
yum list available containerd.io --showduplicates
```

---

## 镜像源地址参考

| 镜像源 | BaseOS URL |
|--------|-----------|
| 阿里云 | `https://mirrors.aliyun.com/centos-stream/9-stream/BaseOS/x86_64/os/` |
| 阿里云内网 | `http://mirrors.cloud.aliyuncs.com/centos-stream/9-stream/BaseOS/x86_64/os/` |
| 清华 TUNA | `https://mirrors.tuna.tsinghua.edu.cn/centos-stream/9-stream/BaseOS/x86_64/os/` |
| 中科大 USTC | `https://mirrors.ustc.edu.cn/centos-stream/9-stream/BaseOS/x86_64/os/` |
| 官方 | `https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/` |
