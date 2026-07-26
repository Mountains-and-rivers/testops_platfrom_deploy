# K8s Cluster Deploy — Kubernetes 集群自动化部署模块

## 概述

基于 Python + Click + Paramiko 实现的 Kubernetes 生产集群全自动化部署模块。覆盖从环境预检、系统初始化、容器运行时安装、K8s 组件部署到集群健康校验的完整生命周期管理。

**核心特性：**
- ✅ Click 构建 CLI，Paramiko SSH 远程操控 CentOS Stream 9 服务器
- ✅ 容器运行时 Containerd 1.7.x
- ✅ 支持 K8s v1.29 / v1.30 / v1.31 指定版本安装（YAML 配置切换）
- ✅ install 前强制执行 pre_check，校验不通过立即终止
- ✅ 8 阶段工作流执行，状态持久化 `runtime/workflow.state`，支持断点续跑
- ✅ 零硬编码：所有配置剥离至 YAML，公共能力复用 `common/` 工具类
- ✅ 完整日志：任何阶段失败输出节点信息 + 命令 + 异常堆栈

## 目录结构

```
k8s_cluster_deploy/
├── .gitignore
├── README.md                                   # 本文档
├── module_main.py                              # 组件独立 CLI 入口（click 实现）
├── requirements.txt                            # 组件私有依赖
│
├── config/                                     # 组件专属静态配置（零硬编码）
│   ├── cluster_info.yaml                       # K8s 集群基础信息：Pod/Service 网段、CNI、域名、etcd
│   ├── node_list.yaml                          # 节点清单：Master/Worker 角色、IP、SSH 端口、账号、标签
│   ├── software_version.yaml                   # 允许选择的 K8s 目标版本清单及兼容性矩阵
│   ├── system_init.yaml                        # 系统初始化参数：swap/selinux/防火墙/内核/limits
│   ├── backup_policy.yaml                      # 数据备份策略：etcd 快照、证书、调度、保留
│   └── uninstall_rules.yaml                    # 卸载执行规则：drain→reset→卸载包→清理残留
│
├── src/
│   ├── __init__.py
│   ├── constants.py                            # 模块内常量、DeployStage 枚举、NodeRole 枚举、Paths 路径常量
│   │
│   ├── workflow/                               # 工作流调度子包
│   │   ├── __init__.py
│   │   ├── pipeline.py                         # K8sDeployPipeline：顺序调度、失败停止、断点续跑、状态查询
│   │   └── workflow_exception.py               # 10 种阶段异常：PreCheck/SystemInit/Containerd/KubeComp/Master/Node/CNI/Verify/Token
│   │
│   ├── stages/                                 # 分阶段业务逻辑（8 阶段）
│   │   ├── __init__.py
│   │   ├── stage0_pre_check.py                 # 环境预检：OS/CPU/内存/磁盘/Swap/SELinux/防火墙/内核模块
│   │   ├── stage1_sys_init.py                  # 系统初始化：关闭 swap/selinux/firewalld、内核参数、limits、NTP
│   │   ├── stage2_containerd_setup.py          # Containerd 安装：YUM安装、cgourp=systemd、镜像加速、启动验证
│   │   ├── stage3_kube_components.py           # K8s 组件：配置 YUM 源、安装 kubeadm/kubectl/kubelet、kubelet 参数
│   │   ├── stage4_master_init.py               # Master 初始化：kubeadm init、kubectl 配置、join token 生成、污点管理
│   │   ├── stage5_node_join.py                 # Node 加入：kubeadm join、标签设置、Token 过期处理
│   │   ├── stage6_cni_deploy.py                # CNI 部署：Calico manifest 下载、Pod 网段修改、等待就绪
│   │   └── stage7_cluster_verify.py            # 健康校验：节点状态/Pod 状态/DNS解析/Pod生命周期测试
│   │
│   ├── check.py                                # 环境预检入口：仅执行 Stage 0
│   ├── install.py                              # 完整安装入口：注册全部 8 阶段 → 顺序执行
│   ├── uninstall.py                            # 完整卸载入口：逆序 drain→reset→卸载→清理（幂等）
│   ├── upgrade.py                              # 【预留】版本升级入口
│   ├── rollback.py                             # 【预留】升级回滚入口
│   └── backup.py                               # 数据备份：etcd 快照 + 证书 + kubeadm 配置
│
├── scripts/shell/                              # 附属 Shell 脚本目录
├── runtime/                                    # 运行时目录（gitignore，自动生成）
│   ├── workflow.state                          # 工作流状态持久化文件（YAML）
│   ├── temp_cache/                             # 临时缓存：join 命令、临时配置文件
│   └── logs/                                   # 日志目录：check/install/uninstall/upgrade/backup.log
│
└── reports/                                    # 报告输出目录
    ├── verify_reports/                         # 健康校验报告
    └── backup_files/                           # 备份文件存储
```

## 支持版本

| 组件 | 支持版本 | 配置位置 |
|------|---------|---------|
| **Kubernetes** | **v1.29.6 / v1.30.2 / v1.31.x** | `config/software_version.yaml` → `kubernetes.default` |
| Containerd | 1.7.x (1.7.11 / 1.7.13 / 1.7.15) | `config/software_version.yaml` → `containerd.default` |
| runc | 1.1.10 / 1.1.12 | `config/software_version.yaml` → `runc.default` |
| CNI Plugins | 1.3.0 / 1.4.0 | `config/software_version.yaml` → `cni_plugins.default` |
| Calico | v3.26.4 / v3.27.0 / v3.27.3 | `config/software_version.yaml` → `calico.default` |
| etcd | 3.5.11 / 3.5.12 | `config/software_version.yaml` → `etcd.default` |
| 目标 OS | **CentOS Stream 9** / RHEL 8.x | `config/system_init.yaml` |

## 部署流程（8 阶段详解）

```
     ┌─────────────────────────────────────────────────────────────────┐
     │                    K8s 集群部署流水线 (8 Stage)                    │
     └─────────────────────────────────────────────────────────────────┘

  Stage 0          Stage 1          Stage 2            Stage 3
┌──────────┐    ┌──────────┐    ┌────────────┐    ┌──────────────┐
│ 环境预检  │───→│系统初始化 │───→│Containerd  │───→│K8s 组件安装  │
│ 扫描      │    │          │    │安装配置     │    │kubeadm/      │
│          │    │swap off  │    │            │    │kubectl/      │
│CPU/RAM/  │    │selinux   │    │cgroup      │    │kubelet       │
│Disk/Swap │    │firewalld │    │systemd     │    │              │
│SELinux/  │    │sysctl    │    │镜像加速     │    │YUM源配置     │
│Firewall  │    │limits    │    │            │    │              │
└──────────┘    └──────────┘    └────────────┘    └──────────────┘
                                                         │
                                                         ▼
  Stage 7          Stage 6          Stage 5        ┌──────────────┐
┌──────────┐    ┌──────────┐    ┌──────────┐      │  Stage 4     │
│ 集群健康  │←───│CNI 部署   │←───│Node 加入  │←─────│ Master 初始化│
│ 校验      │    │          │    │          │      │              │
│          │    │Calico    │    │kubeadm   │      │kubeadm init  │
│Node状态  │    │manifest  │    │join      │      │kubectl配置   │
│Pod状态   │    │VXLAN/    │    │label打标  │      │join token    │
│DNS测试   │    │IPIP      │    │token管理  │      │证书管理      │
│Pod生命   │    │等待就绪   │    │          │      │污点移除      │
│周期测试  │    │          │    │          │      │              │
└──────────┘    └──────────┘    └──────────┘      └──────────────┘
```

### 各阶段详细说明

#### Stage 0: 环境预检扫描 (`stage0_pre_check.py`)

**强制执行规则：install 命令先执行此阶段，任何节点不通过 → 立即终止，不进入任何安装步骤。**

| 检查项 | 要求 | 配置来源 |
|--------|------|---------|
| OS 版本 | CentOS Stream 9 / RHEL 8.x | 输出 `/etc/os-release` |
| CPU 核数 | ≥ 2 核（Master 建议 4 核） | `HardwareRequirements.MIN_CPU_CORES` |
| 内存 | ≥ 2048 MB（Master 建议 4096 MB） | `HardwareRequirements.MIN_MEMORY_MB` |
| 磁盘 | ≥ 40 GB（建议 ≥ 100 GB） | `HardwareRequirements.MIN_DISK_GB` |
| Swap | 检测是否激活 | `swapon --show` |
| SELinux | 检测当前模式 | `getenforce` |
| 防火墙 | 检测 firewalld 状态 | `systemctl is-active firewalld` |
| 内核版本 | 输出 `uname -r` 结果 | — |
| SSH 连通性 | 建立连接测试 | — |

错误输出格式：
```
✗ node-01 (10.0.0.21) [worker]
  预检失败: CPU 核数不足: 1 < 2
```

#### Stage 1: 系统标准化初始化 (`stage1_sys_init.py`)

| 操作 | 命令/配置 | 是否可回滚 |
|------|----------|-----------|
| 关闭 SELinux | `setenforce 0; sed -i SELINUX=disabled` | 是 |
| 关闭 Swap | `swapoff -a; 注释 /etc/fstab swap 行` | 是 |
| 停止防火墙 | `systemctl stop/disable firewalld` | 是 |
| 加载内核模块 | `modprobe overlay br_netfilter` | — |
| 内核参数 | 写入 `/etc/sysctl.d/99-kubernetes.conf` | 删除文件 |
| 资源限制 | 写入 `/etc/security/limits.d/99-kubernetes.conf` | 删除文件 |
| NTP 时间同步 | `systemctl enable chronyd --now` | — |

#### Stage 2: 容器运行时安装 (`stage2_containerd_setup.py`)

| 操作 | 说明 |
|------|------|
| 安装 containerd | `yum install -y containerd.io-{version}` |
| 生成默认配置 | `containerd config default > /etc/containerd/config.toml` |
| Cgroup 驱动 | `SystemdCgroup = true`（K8s 要求） |
| 镜像加速 | 从 `global_config/mirror_repo.yaml` 读取 registry mirror |
| 启动验证 | `systemctl enable containerd --now` + `systemctl is-active` 确认 |

#### Stage 3: K8s 组件安装 (`stage3_kube_components.py`)

| 操作 | 说明 |
|------|------|
| YUM 源配置 | 添加阿里云 Kubernetes YUM 仓库 |
| 安装组件 | `yum install -y kubeadm-{ver} kubectl-{ver} kubelet-{ver}` |
| kubelet 配置 | `--cgroup-driver=systemd --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock` |
| 启用 kubelet | `systemctl enable kubelet`（进入等待状态，kubeadm init 后接管） |

#### Stage 4: Master 节点初始化 (`stage4_master_init.py`)

| 操作 | 说明 |
|------|------|
| 生成配置 | 动态生成 `kubeadm-init.yaml`（InitConfiguration + ClusterConfiguration + KubeletConfiguration） |
| 集群初始化 | `kubeadm init --config=/tmp/kubeadm-init.yaml --upload-certs` |
| kubectl 配置 | `cp /etc/kubernetes/admin.conf ~/.kube/config` |
| Join Token | `kubeadm token create --print-join-command` → 写入 `runtime/temp_cache/join_command.sh` + 存入 workflow.state |
| 污点管理 | 按配置决定是否移除 `node-role.kubernetes.io/control-plane` 污点 |

生成的 `kubeadm-init.yaml` 关键字段：
```yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: <master_ip>
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  name: <hostname>
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.29.6
controlPlaneEndpoint: "k8s-api.testops.local:6443"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

#### Stage 5: Node 节点加入 (`stage5_node_join.py`)

| 操作 | 说明 |
|------|------|
| 执行 join | 从 workflow.state 获取 join_command → 在各 Worker 执行 |
| Token 过期处理 | 检测 stderr 中 "token" + "expired" → 抛出 `TokenExpiredError` |
| 标签设置 | 按 `node_list.yaml` 中 `labels` 配置执行 `kubectl label` |
| 部分失败 | 单个节点失败不影响其他节点（独立执行） |

#### Stage 6: CNI 网络插件部署 (`stage6_cni_deploy.py`)

| 操作 | 说明 |
|------|------|
| 下载 manifest | 优先从 ghproxy 镜像下载，回退到 GitHub 官方地址 |
| Pod 网段修改 | 替换默认 `192.168.0.0/16` 为配置的 `pod_cidr` |
| 隧道模式 | 支持 VXLAN（默认）/ IPIP，通过修改 `vxlanMode` 控制 |
| 部署 | `kubectl apply -f /tmp/calico.yaml` |
| 等待就绪 | `kubectl wait` calico-node 和 calico-kube-controllers（超时 180s） |

#### Stage 7: 集群健康校验 (`stage7_cluster_verify.py`)

| 检查项 | 验证方式 | 通过标准 |
|--------|---------|---------|
| 节点状态 | `kubectl get nodes` | 全部节点 Status = Ready |
| 核心 Pod 状态 | `kubectl get pods -n kube-system` | 全部 Running/Completed |
| DNS 解析 | 创建 busybox Pod → `nslookup kubernetes.default` | 返回 Service IP |
| Pod 生命周期 | 创建 nginx Pod → 等待 Ready → 删除 | Running → 成功删除 |

## 独立 CLI 命令

### 安装部署

```bash
# 完整安装（自动先执行预检）
python -m modules.k8s_cluster_deploy.module_main install

# 从指定阶段开始（断点续跑）
python -m modules.k8s_cluster_deploy.module_main install --stage 3

# 预览安装计划（不执行）
python -m modules.k8s_cluster_deploy.module_main install --dry-run
```

### 环境预检

```bash
# 仅执行预检（不安装）
python -m modules.k8s_cluster_deploy.module_main check
```

### 卸载

```bash
# 完整卸载（需要确认）
python -m modules.k8s_cluster_deploy.module_main uninstall

# 强制卸载（跳过确认）
python -m modules.k8s_cluster_deploy.module_main uninstall --force
```

卸载执行顺序（严格逆序，幂等设计）：
```
1. drain worker 节点 Pods (kubectl drain --force --ignore-daemonsets)
2. 从集群删除 worker 节点 (kubectl delete node)
3. 删除 CNI (kubectl delete -f calico.yaml)
4. kubeadm reset master 节点 (kubeadm reset --force)
5. 卸载 kubeadm/kubectl/kubelet (yum remove)
6. 停止并卸载 containerd (systemctl stop + yum remove)
7. 清理残留目录 (/etc/kubernetes /var/lib/kubelet /etc/cni /var/lib/etcd)
8. 清理 CNI 网络接口 (ip link delete cni0/cali*/flannel.1)
9. 清理 iptables 规则 (iptables -F/-X)
```

### 备份

```bash
python -m modules.k8s_cluster_deploy.module_main backup
```

备份内容：
- etcd 快照 (`etcdctl snapshot save`)
- 集群证书 (`/etc/kubernetes/pki` 打包)
- kubeadm 配置文件 (`kubeadm-config.yaml`, `admin.conf`)
- 备份文件存储到 `reports/backup_files/backup_{timestamp}/`

### 状态查询

```bash
python -m modules.k8s_cluster_deploy.module_main status
```

输出示例：
```
组件: k8s_cluster_deploy
工作流: install
进度: 75.0%
────────────────────────────────────────
  ✓ stage0_pre_check [success]
  ✓ stage1_sys_init [success]
  ✓ stage2_containerd_setup [success]
  ✓ stage3_kube_components [success]
  ✓ stage4_master_init [success]
  ✓ stage5_node_join [success]
  ✗ stage6_cni_deploy [failed]
  ○ stage7_cluster_verify [pending]
```

### 升级/回滚（预留）

```bash
python -m modules.k8s_cluster_deploy.module_main upgrade
python -m modules.k8s_cluster_deploy.module_main rollback
```

## 配置文件说明

### `config/cluster_info.yaml` — 集群拓扑

```yaml
cluster_info:
  cluster_name: "testops-prod"
  cluster_domain: "testops.local"
  networking:
    pod_cidr: "10.244.0.0/16"           # Pod 网络，Calico 使用
    service_cidr: "10.96.0.0/12"        # ClusterIP 网段
    service_node_port_range: "30000-32767"
  api_server:
    control_plane_endpoint: "k8s-api.testops.local:6443"
  cni:
    plugin: "calico"
    calico:
      encapsulation: "VXLANCrossSubnet" # VXLANAlways | IPIP | None
  container_runtime:
    engine: "containerd"
```

### `config/node_list.yaml` — 节点清单

```yaml
node_list:
  masters:
    - hostname: "k8s-master-01"
      ip: "10.0.0.10"
      ssh:
        port: 22
        username: "root"
      role: "control-plane"
      taints: []
  workers:
    - hostname: "k8s-node-01"
      ip: "10.0.0.21"
      ssh:
        port: 22
        username: "root"
      role: "worker"
      labels:
        node-role.kubernetes.io/worker: ""
        testops.io/app: "true"
```

> **注意：** SSH 端口/账号支持节点级覆盖，未配置时回退到 `global_config/ssh_global.yaml`。

### `config/software_version.yaml` — 版本清单

```yaml
software_version:
  kubernetes:
    default: "1.29.6"                  # 默认安装版本
    available:                          # 可选版本列表
      - "1.29.6"
      - "1.30.2"
      - "1.31.0"
  containerd:
    default: "1.7.13"
  calico:
    default: "v3.27.0"
  # 版本兼容性矩阵（自动校验）
  compatibility:
    kubernetes_1_29:
      containerd: ">=1.7.0,<1.8.0"
      calico: ">=3.27.0,<3.28.0"
```

### `config/system_init.yaml` — 系统初始化

```yaml
system_init:
  selinux: { mode: "disabled" }
  swap: { disable_permanently: true }
  firewall: { stop_service: true, disable_service: true, manager: "firewalld" }
  kernel_modules: { required: [overlay, br_netfilter] }
  sysctl_params:
    net.bridge.bridge-nf-call-iptables: 1
    net.ipv4.ip_forward: 1
    vm.swappiness: 0
    # ... 共 20+ 项内核参数
  limits: { nofile: 655360, nproc: 655360 }
  ntp: { enabled: true, service: "chronyd" }
```

### `config/backup_policy.yaml` — 备份策略

```yaml
backup_policy:
  scope:
    etcd_snapshot: true
    certificates: true
    kubeadm_config: true
  etcd:
    snapshot_dir: "/opt/testops/backup/etcd"
    local_retention_count: 7
  schedule:
    cron: "0 2 * * *"                   # 每天凌晨 2:00
    auto_before_deploy: true            # 部署前自动备份
  retention:
    max_backups: 30
    max_age_days: 90
```

### `config/uninstall_rules.yaml` — 卸载规则

```yaml
uninstall_rules:
  drain_worker_nodes:
    timeout: 300
    force: true
    ignore_daemonsets: true
  reset_master:
    kubeadm_reset_flags: ["--force", "--cri-socket=unix:///var/run/containerd/containerd.sock"]
  remove_k8s_packages:
    packages: [kubeadm, kubectl, kubelet]
  cleanup_system:
    cleanup_cni_interfaces: true
    cleanup_iptables: true
    cleanup_directories:
      - /etc/kubernetes/
      - /var/lib/kubelet/
      - /etc/cni/
      - /opt/cni/
      - /var/lib/etcd/
```

## 异常处理

### 阶段异常类型

| 异常类 | 触发场景 | 错误码 |
|--------|---------|--------|
| `PreCheckFailedError` | 节点硬件/系统不满足最低要求 | `K8S_PRECHECK_FAILED` |
| `SystemInitError` | 系统初始化操作失败 | `K8S_SYS_INIT_FAILED` |
| `ContainerdSetupError` | containerd 安装/启动失败 | `K8S_CONTAINERD_SETUP_FAILED` |
| `KubeComponentInstallError` | kubeadm/kubectl/kubelet 安装失败 | `K8S_COMPONENT_INSTALL_FAILED` |
| `MasterInitError` | kubeadm init 失败 | `K8S_MASTER_INIT_FAILED` |
| `NodeJoinError` | kubeadm join 失败 | `K8S_NODE_JOIN_FAILED` |
| `CNIDeployError` | Calico 部署/等待就绪失败 | `K8S_CNI_DEPLOY_FAILED` |
| `ClusterVerifyError` | 集群健康校验未通过 | `K8S_CLUSTER_VERIFY_FAILED` |
| `TokenExpiredError` | Join Token 已过期 | `K8S_TOKEN_EXPIRED` |

### 错误输出格式

任何阶段失败时，输出包含：
```
✗ 阶段失败: stage4_master_init — K8S_MASTER_INIT_FAILED

节点: k8s-master-01 (10.0.0.10)
操作: kubeadm init
命令: kubeadm init --config=/tmp/kubeadm-init.yaml --upload-certs
退出码: 1
stderr:
  [ERROR ImagePull]: failed to pull image registry.k8s.io/...
异常堆栈:
  Traceback (most recent call last):
    File "src/stages/stage4_master_init.py", line 95, in run_master_init
      raise MasterInitError(hostname, f"kubeadm init failed")
  ...
```

同时写入 `runtime/logs/install.log`。

## 故障排查

### Stage 0 预检失败

```bash
# 手动验证 SSH 连通性
ssh -i ~/.ssh/id_rsa root@<node_ip>

# 检查系统版本
ssh root@<node_ip> "cat /etc/os-release"

# 检查硬件资源
ssh root@<node_ip> "nproc && free -m && df -h /"

# 修改配置后重新预检
python -m modules.k8s_cluster_deploy.module_main check
```

### Stage 2 Containerd 安装失败

```bash
# 手动检查 containerd 是否正确安装
ssh root@<node_ip> "containerd --version"
ssh root@<node_ip> "systemctl status containerd"

# 检查配置文件
ssh root@<node_ip> "containerd config dump | grep SystemdCgroup"
```

### Stage 4 Master 初始化失败

```bash
# 查看 kubeadm 详细日志
ssh root@<master_ip> "journalctl -xeu kubelet | tail -100"

# 检查镜像是否可用
ssh root@<master_ip> "kubeadm config images pull --config=/tmp/kubeadm-init.yaml"

# 重置后重试
ssh root@<master_ip> "kubeadm reset --force"
python -m modules.k8s_cluster_deploy.module_main install --stage 4
```

### Stage 5 Node 加入失败

```bash
# Token 过期（24h），在 Master 上重新生成
ssh root@<master_ip> "kubeadm token create --print-join-command"

# 将输出手动写入 runtime/temp_cache/join_command.sh
# 然后从 Stage 5 恢复
python -m modules.k8s_cluster_deploy.module_main install --stage 5
```

### Stage 6 Calico 部署失败

```bash
# 检查 Calico Pods 状态
ssh root@<master_ip> "kubectl get pods -n kube-system | grep calico"
ssh root@<master_ip> "kubectl describe pod -n kube-system -l k8s-app=calico-node"

# 检查 Calico 配置
ssh root@<master_ip> "kubectl get installation -o yaml 2>/dev/null || echo 'Calico CRD 未就绪'"
```

## 使用示例

### 完整部署示例

```bash
# 1. 修改配置
vim config/node_list.yaml        # 填写服务器 IP 和 SSH 信息
vim config/cluster_info.yaml     # 确认 Pod/Service 网段
vim config/software_version.yaml # 选择 K8s 版本（默认 v1.29.6）

# 2. 环境预检
python -m modules.k8s_cluster_deploy.module_main check

# 3. 执行部署
python -m modules.k8s_cluster_deploy.module_main install

# 4. 验证集群
ssh root@<master_ip>
kubectl get nodes
kubectl get pods -A
```

### 断点续跑示例

```bash
# 假设 Stage 4 (Master 初始化) 失败，修复问题后：
python -m modules.k8s_cluster_deploy.module_main install --stage 4
```

### 卸载示例

```bash
# 完整卸载（会先询问确认）
python -m modules.k8s_cluster_deploy.module_main uninstall

# 强制卸载
python -m modules.k8s_cluster_deploy.module_main uninstall --force
```

### 备份示例

```bash
# 手动备份
python -m modules.k8s_cluster_deploy.module_main backup

# 备份文件位于
ls reports/backup_files/backup_20260725_143000/
# 输出：
#   etcd-snapshot-20260725_143000.db
#   pki-backup-20260725_143000.tar.gz
#   kubeadm-config.yaml
#   admin.conf
```

## 与其他组件的协作

```
global_config/ssh_global.yaml    → 提供 SSH 默认超时/重试/并发参数
global_config/mirror_repo.yaml   → 提供 YUM 源、镜像 Registry 地址
global_config/network_policy.yaml → 提供防火墙端口策略
common/exceptions.py             → 复用全局异常类
common/logger.py                 → 复用统一日志管理器
common/ssh_client.py             → 复用 SSH 客户端封装
common/yaml_helper.py            → 复用 YAML 配置读写工具
common/task_base.py              → 复用任务基类（生命周期钩子）
common/workflow_state.py         → 复用状态持久化管理器
common/report_generator.py       → 复用报告生成工具
```
