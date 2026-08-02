"""
统一远程命令执行器

封装 SSH 连接、认证、执行、重试，所有 stage 通过一个接口调用，
不再各自构造 SSHClient。

用法:
    executor = RemoteExecutor()
    exit_code, stdout, stderr = executor.exec("k8s-master-01", "hostname")
    stdout = executor.exec_ok("k8s-node-01", "hostname", sudo=True)
"""

import os
import sys
from typing import Tuple, Optional, Dict, List

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.logger import get_logger
from common.yaml_helper import YAMLHelper
from common.ssh_client import SSHClient

logger = get_logger(__name__)


class RemoteExecutor:
    """
    统一远程命令执行器。

    - 自动从 node_list.yaml 读取 SSH 认证信息（IP、端口、用户名、密码/密钥）
    - 连接复用：同一节点多次调用共享一个连接
    - 自动 keepalive，防止长连接断开
    - 统一的重试和超时策略

    用法:
        executor = RemoteExecutor()
        executor.exec("k8s-master-01", "kubeadm init ...", sudo=True, timeout=600)
        executor.exec_ok("k8s-node-01", "systemctl start containerd", sudo=True)
        executor.close_all()
    """

    def __init__(self, node_list_path: str = None):
        """
        Args:
            node_list_path: node_list.yaml 路径，默认自动查找
        """
        if node_list_path is None:
            node_list_path = os.path.join(
                PROJECT_ROOT,
                "pkg_deploy/k8s_cluster/config/node_list.yaml"
            )
        self._node_list_path = node_list_path
        self._node_list: Dict = {}
        self._connections: Dict[str, SSHClient] = {}   # hostname → SSHClient
        self._loaded = False

    # ------------------------------------------------------------
    # 配置加载
    # ------------------------------------------------------------
    def _ensure_loaded(self):
        """懒加载节点清单。"""
        if self._loaded:
            return
        self._node_list = YAMLHelper.load(self._node_list_path) or {}
        self._loaded = True

    def get_node_config(self, hostname: str) -> dict:
        """根据主机名查找节点配置（含 ssh 认证信息）。"""
        self._ensure_loaded()
        nodes = self._get_all_nodes()
        for n in nodes:
            if n.get("hostname") == hostname:
                return n
        raise ValueError(f"节点清单中未找到主机: {hostname}")

    def _get_all_nodes(self) -> List[dict]:
        """返回所有节点（master + worker）的列表。"""
        node_list = self._node_list.get("node_list", {})
        result = []
        for m in node_list.get("masters", []):
            result.append(m)
        for w in node_list.get("workers", []):
            result.append(w)
        return result

    def get_master(self) -> dict:
        """返回第一个 master 节点配置。"""
        self._ensure_loaded()
        masters = self._node_list.get("node_list", {}).get("masters", [])
        if not masters:
            raise ValueError("节点清单中无 master 节点")
        return masters[0]

    def get_workers(self) -> List[dict]:
        """返回所有 worker 节点配置。"""
        self._ensure_loaded()
        return self._node_list.get("node_list", {}).get("workers", [])

    def get_all_nodes(self) -> List[dict]:
        """返回所有节点配置。"""
        self._ensure_loaded()
        return self._get_all_nodes()

    # ------------------------------------------------------------
    # SSH 客户端获取（连接复用）
    # ------------------------------------------------------------
    def get_client(self, hostname: str) -> SSHClient:
        """获取指定节点的 SSHClient（自动从配置文件读取认证信息，复用连接）。"""
        if hostname in self._connections:
            client = self._connections[hostname]
            if client.is_connected:
                return client
            # 连接已断，关闭并重建
            try:
                client.close()
            except Exception:
                pass

        node = self.get_node_config(hostname)
        ip = node["ip"]
        ssh_cfg = node.get("ssh", {})

        client = SSHClient(
            host=ip,
            username=ssh_cfg.get("username", "root"),
            port=ssh_cfg.get("port", 22),
            password=ssh_cfg.get("password"),
            key_file=ssh_cfg.get("key_file"),
        )
        client.connect()
        self._connections[hostname] = client
        return client

    def close_client(self, hostname: str):
        """关闭指定节点的连接。"""
        client = self._connections.pop(hostname, None)
        if client:
            try:
                client.close()
            except Exception:
                pass

    def close_all(self):
        """关闭所有连接。"""
        for hostname in list(self._connections.keys()):
            self.close_client(hostname)

    # ------------------------------------------------------------
    # 命令执行
    # ------------------------------------------------------------
    def exec(
        self,
        hostname: str,
        command: str,
        timeout: int = 600,
        sudo: bool = False,
        retry_on_failure: bool = True,
        max_retries: int = 3,
    ) -> Tuple[int, str, str]:
        """
        在指定节点上执行命令。

        Args:
            hostname: 节点主机名（对应 node_list.yaml 中的 hostname）
            command: 要执行的命令
            timeout: 命令执行超时（秒）
            sudo: 是否 sudo 执行
            retry_on_failure: 失败是否重试
            max_retries: 最大重试次数

        Returns:
            (exit_code, stdout, stderr)
        """
        client = self.get_client(hostname)
        return client.exec_command(
            command,
            timeout=timeout,
            sudo=sudo,
            retry_on_failure=retry_on_failure,
            max_retries=max_retries,
        )

    def exec_ok(
        self,
        hostname: str,
        command: str,
        timeout: int = 600,
        sudo: bool = False,
    ) -> str:
        """
        执行命令，成功返回 stdout，失败抛异常。
        """
        client = self.get_client(hostname)
        return client.exec_command_ok(command, timeout=timeout, sudo=sudo)

    # ------------------------------------------------------------
    # 批量执行（遍历所有节点）
    # ------------------------------------------------------------
    def exec_on_all(
        self,
        command: str,
        timeout: int = 600,
        sudo: bool = False,
        include_masters: bool = True,
        include_workers: bool = True,
    ) -> Dict[str, Tuple[int, str, str]]:
        """
        在所有节点上执行相同命令。

        Returns:
            {hostname: (exit_code, stdout, stderr)}
        """
        nodes = self.get_all_nodes()
        results = {}
        for node in nodes:
            hostname = node["hostname"]
            role = node.get("role", "")
            if not include_masters and "control-plane" in role:
                continue
            if not include_workers and "worker" in role:
                continue
            logger.info(f"[{hostname}] 执行: {command[:100]}...")
            results[hostname] = self.exec(hostname, command, timeout=timeout, sudo=sudo)
        return results

    # ------------------------------------------------------------
    # 便捷方法
    # ------------------------------------------------------------
    def upload(self, hostname: str, local_path: str, remote_path: str):
        """上传文件到指定节点。"""
        client = self.get_client(hostname)
        client.upload_file(local_path, remote_path)

    def download(self, hostname: str, remote_path: str, local_path: str):
        """从指定节点下载文件。"""
        client = self.get_client(hostname)
        client.download_file(remote_path, local_path)

    def test_connection(self, hostname: str) -> bool:
        """测试节点连通性。"""
        try:
            client = self.get_client(hostname)
            return client.test_connection()
        except Exception:
            return False

    # ------------------------------------------------------------
    # 上下文管理器
    # ------------------------------------------------------------
    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close_all()
        return False
