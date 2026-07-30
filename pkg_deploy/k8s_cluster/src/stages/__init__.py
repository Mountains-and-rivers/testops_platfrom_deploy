"""
K8s Cluster Deploy — 分阶段业务逻辑包

部署 8 阶段:
  Stage 0: 环境预检扫描
  Stage 1: 系统标准化初始化
  Stage 2: 容器运行时安装 (containerd)
  Stage 3: kubeadm/kubectl/kubelet 安装
  Stage 4: Master 节点集群初始化
  Stage 5: Node 节点加入集群
  Stage 6: Calico 网络插件部署
  Stage 7: 集群部署后健康校验
"""
