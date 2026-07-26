"""
Stage 3: kubeadm / kubectl / kubelet 安装

在所有节点上：
- 添加 Kubernetes YUM 仓库（pkgs.k8s.io 官方源）
- 安装指定版本的 kubeadm、kubectl、kubelet
- 配置 kubelet（cgroup 驱动 + containerd socket）
- 启用 kubelet 服务（等待 kubeadm init 接管）
"""

import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.workflow_state import WorkflowStateManager
from common.yaml_helper import YAMLHelper
from common.ssh_client import SSHClient
from src.workflow.workflow_exception import KubeComponentInstallError

logger = get_logger(__name__)

CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "config")

# K8s 官方 RPM 仓库模板
K8S_REPO_TEMPLATE = (
    "[kubernetes]\n"
    "name=Kubernetes\n"
    "baseurl=https://pkgs.k8s.io/core:/stable:/v{minor_version}/rpm/\n"
    "enabled=1\n"
    "gpgcheck=0\n"
)


def _get_all_nodes(node_list: dict) -> list:
    """提取所有节点。"""
    nodes = []
    for master in node_list.get("node_list", {}).get("masters", []):
        nodes.append(master)
    for worker in node_list.get("node_list", {}).get("workers", []):
        nodes.append(worker)
    return nodes


def _get_minor_version(k8s_version: str) -> str:
    """从完整版本号提取 minor 版本（如 1.36.3 → 1.36）。"""
    parts = k8s_version.split(".")
    if len(parts) >= 2:
        return f"{parts[0]}.{parts[1]}"
    return k8s_version


def _install_kube_on_node(node: dict, k8s_version: str) -> None:
    """在单个节点上安装 Kubernetes 组件。"""
    hostname = node["hostname"]
    ip = node["ip"]
    ssh_cfg = node.get("ssh", {})

    ssh = SSHClient(
        host=ip,
        username=ssh_cfg.get("username", "root"),
        port=ssh_cfg.get("port", 22),
        password=ssh_cfg.get("password"),
        key_file=ssh_cfg.get("key_file"),
    )

    try:
        ssh.connect()
        minor_ver = _get_minor_version(k8s_version)
        logger.info(f"[{hostname}] 开始安装 K8s 组件 v{k8s_version} (repo: v{minor_ver})...")

        # 1. 添加 K8s YUM 仓库（幂等：每次覆盖写入）
        repo_content = K8S_REPO_TEMPLATE.format(minor_version=minor_ver)
        ssh.exec_command(
            f"cat > /etc/yum.repos.d/kubernetes.repo << 'K8S_EOF'\n{repo_content}\nK8S_EOF",
            sudo=True
        )
        logger.debug(f"[{hostname}] K8s repo 已配置: v{minor_ver}")

        # 2. 安装 kubeadm/kubectl/kubelet（yum install 自带幂等）
        exit_code, stdout, stderr = ssh.exec_command(
            f"yum install -y "
            f"kubeadm-{k8s_version} kubectl-{k8s_version} kubelet-{k8s_version}",
            sudo=True, timeout=300
        )
        if exit_code != 0:
            raise KubeComponentInstallError(
                hostname, "kubeadm/kubectl/kubelet",
                f"安装失败 (exit={exit_code}): {stderr[:300]}"
            )

        # 获取实际安装的版本
        _, version_out, _ = ssh.exec_command(
            "kubeadm version -o short 2>/dev/null || echo unknown",
            sudo=True
        )
        logger.info(f"[{hostname}] K8s 组件已安装: {version_out.strip()}")

        # 3. 配置 kubelet（cgroup 驱动 + containerd socket）
        kubelet_config = (
            'KUBELET_EXTRA_ARGS="--cgroup-driver=systemd '
            '--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock"'
        )
        ssh.exec_command(
            f"echo '{kubelet_config}' > /etc/sysconfig/kubelet",
            sudo=True
        )
        logger.debug(f"[{hostname}] kubelet 配置已写入")

        # 4. 启用 kubelet（不启动，等待 kubeadm init 接管）
        ssh.exec_command_ok("systemctl enable kubelet 2>/dev/null || true", sudo=True)

        # 5. 安装后扫描验证
        _verify_kube(ssh, hostname, k8s_version)
        logger.info(f"[{hostname}] K8s 组件安装完成 ✓")

    except KubeComponentInstallError:
        raise
    except Exception as e:
        raise KubeComponentInstallError(hostname, "kubeadm/kubectl/kubelet", str(e))
    finally:
        ssh.close()


def _verify_kube(ssh: SSHClient, hostname: str, expected_version: str) -> None:
    """安装后扫描验证 kubeadm/kubectl/kubelet 版本、二进制、配置。"""
    logger.info(f"[{hostname}] 🔍 安装后扫描验证...")
    checks = []
    # 去掉版本号可能带有的 v 前缀
    expected_ver = expected_version.lstrip("v")

    # 1. kubeadm — rpm 查询版本（最可靠）
    _, rpm_out, _ = ssh.exec_command(
        "rpm -q --queryformat '%{VERSION}' kubeadm 2>/dev/null || echo MISSING"
    )
    rpm_ver = rpm_out.strip()
    if rpm_ver and rpm_ver != "MISSING":
        status = "PASS" if rpm_ver == expected_ver else "WARN"
        checks.append(("kubeadm版本", status, f"{rpm_ver} (期望 {expected_ver})"))
    else:
        checks.append(("kubeadm版本", "FAIL", "未安装"))

    # 2. kubectl — rpm 查询
    _, rpm_out, _ = ssh.exec_command(
        "rpm -q --queryformat '%{VERSION}' kubectl 2>/dev/null || echo MISSING"
    )
    rpm_ver = rpm_out.strip()
    if rpm_ver and rpm_ver != "MISSING":
        status = "PASS" if rpm_ver == expected_ver else "WARN"
        checks.append(("kubectl版本", status, f"{rpm_ver} (期望 {expected_ver})"))
    else:
        checks.append(("kubectl版本", "FAIL", "未安装"))

    # 3. kubelet — rpm 查询
    _, rpm_out, _ = ssh.exec_command(
        "rpm -q --queryformat '%{VERSION}' kubelet 2>/dev/null || echo MISSING"
    )
    rpm_ver = rpm_out.strip()
    if rpm_ver and rpm_ver != "MISSING":
        status = "PASS" if rpm_ver == expected_ver else "WARN"
        checks.append(("kubelet版本", status, f"{rpm_ver} (期望 {expected_ver})"))
    else:
        checks.append(("kubelet版本", "FAIL", "未安装"))

    # 4. 二进制文件可执行
    binaries_ok = []
    for binary in ["kubeadm", "kubectl", "kubelet"]:
        _, path_out, _ = ssh.exec_command(f"command -v {binary} 2>/dev/null || echo MISSING")
        if "MISSING" not in path_out:
            binaries_ok.append(binary)
    if len(binaries_ok) == 3:
        checks.append(("二进制路径", "PASS", "kubeadm/kubectl/kubelet 均可执行"))
    else:
        missing = set(["kubeadm", "kubectl", "kubelet"]) - set(binaries_ok)
        checks.append(("二进制路径", "FAIL", f"缺失: {missing}"))

    # 5. kubelet 开机自启
    _, enabled, _ = ssh.exec_command("systemctl is-enabled kubelet 2>/dev/null || echo NONE")
    if "enabled" in enabled:
        checks.append(("kubelet自启", "PASS", "enabled"))
    else:
        checks.append(("kubelet自启", "FAIL", enabled.strip()))

    # 6. kubelet 配置文件
    _, cfg, _ = ssh.exec_command(
        "grep -c 'cgroup-driver=systemd' /etc/sysconfig/kubelet 2>/dev/null || echo 0"
    )
    if int(cfg.strip() or 0) > 0:
        checks.append(("kubelet配置", "PASS", "cgroup=systemd + containerd socket"))
    else:
        checks.append(("kubelet配置", "FAIL", "配置缺失或错误"))

    # 7. K8s YUM repo 存在且 URL 正确
    _, repo_url, _ = ssh.exec_command(
        "grep '^baseurl=' /etc/yum.repos.d/kubernetes.repo 2>/dev/null || echo MISSING"
    )
    if "MISSING" not in repo_url:
        # 检查 URL 是否包含正确的 minor 版本
        minor = ".".join(expected_ver.split(".")[:2])
        if minor in repo_url:
            checks.append(("YUM仓库", "PASS", repo_url.strip()[:70]))
        else:
            checks.append(("YUM仓库", "WARN", f"版本不匹配: {repo_url.strip()[:60]}"))
    else:
        checks.append(("YUM仓库", "FAIL", "缺失"))

    # 8. kubelet 服务状态（应 inactive，等待 kubeadm init）
    _, kls, _ = ssh.exec_command("systemctl is-active kubelet 2>/dev/null || echo inactive")
    kls = kls.strip()
    if kls == "inactive":
        checks.append(("kubelet状态", "PASS", "inactive（等待 kubeadm init）"))
    else:
        checks.append(("kubelet状态", "INFO", kls))

    # 汇总
    logger.info(f"  {'─' * 45}")
    passed = sum(1 for _, r, _ in checks if r == "PASS")
    failed = sum(1 for _, r, _ in checks if r == "FAIL")
    for name, result, detail in checks:
        icon = "✅" if result == "PASS" else ("⚠️" if result == "WARN" else ("ℹ️" if result == "INFO" else "❌"))
        logger.info(f"  {icon} {name:12s}: {detail}")
    logger.info(f"  {'─' * 45}")
    logger.info(f"  总计 {len(checks)} 项 | 通过 {passed} | 失败 {failed}")

    if failed > 0:
        raise KubeComponentInstallError(hostname, "安装后验证", f"{failed} 项未通过")


def run_kube_components(state: WorkflowStateManager) -> None:
    """
    在全部节点上安装 Kubernetes 组件。

    Args:
        state: 工作流状态管理器实例
    """
    # 前置校验：Stage 2 必须已通过
    state.require_stage_success("stage2_containerd_setup")

    logger.info("=" * 50)
    logger.info("Stage 3: 开始 K8s 组件安装")
    logger.info("=" * 50)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    version_config = YAMLHelper.load(os.path.join(CONFIG_DIR, "software_version.yaml"))
    k8s_version = version_config.get("software_version", {}).get(
        "kubernetes", {}
    ).get("default", "1.36.3")

    all_nodes = _get_all_nodes(node_list)

    for node in all_nodes:
        _install_kube_on_node(node, k8s_version)

    logger.info(f"K8s 组件安装完成: {len(all_nodes)} 个节点")
    state.set_global("kube_components_installed", True)
    state.set_global("k8s_version", k8s_version)


def rollback_kube_components(state: WorkflowStateManager) -> None:
    """
    回滚 Stage 3：卸载所有节点上的 kubeadm/kubectl/kubelet。

    操作：
    - 停止并禁用 kubelet 服务
    - 卸载 K8s 组件包
    - 删除 YUM 仓库配置
    - 删除 kubelet 配置和数据目录
    """
    logger.info("=" * 50)
    logger.info("Stage 3 Rollback: 回滚 K8s 组件")
    logger.info("=" * 50)

    node_list = YAMLHelper.load(os.path.join(CONFIG_DIR, "node_list.yaml"))
    all_nodes = _get_all_nodes(node_list)

    for node in all_nodes:
        hostname = node["hostname"]
        ip = node["ip"]
        ssh_cfg = node.get("ssh", {})

        ssh = SSHClient(
            host=ip,
            username=ssh_cfg.get("username", "root"),
            port=ssh_cfg.get("port", 22),
            password=ssh_cfg.get("password"),
            key_file=ssh_cfg.get("key_file"),
        )

        try:
            ssh.connect()
            logger.info(f"[{hostname}] 开始卸载 K8s 组件...")

            # 停止 + 禁用
            ssh.exec_command("systemctl stop kubelet 2>/dev/null || true", sudo=True)
            ssh.exec_command("systemctl disable kubelet 2>/dev/null || true", sudo=True)
            # 卸载包
            ssh.exec_command(
                "yum remove -y kubeadm kubectl kubelet 2>/dev/null || true",
                sudo=True, timeout=120
            )
            # 删除仓库、配置、数据
            ssh.exec_command("rm -f /etc/yum.repos.d/kubernetes.repo", sudo=True)
            ssh.exec_command("rm -f /etc/sysconfig/kubelet", sudo=True)
            ssh.exec_command("rm -rf /var/lib/kubelet /etc/kubernetes", sudo=True)

            logger.info(f"[{hostname}] K8s 组件卸载完成 ✓")

        except Exception as e:
            logger.warning(f"[{hostname}] 回滚时出现错误（可忽略）: {e}")
        finally:
            ssh.close()

    logger.info("K8s 组件回滚完成")
    state.set_global("kube_components_installed", False)
