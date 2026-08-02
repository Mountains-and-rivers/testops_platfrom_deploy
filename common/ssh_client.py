"""
SSH 远程执行、文件上传下载封装。

基于 paramiko 实现，提供统一的 SSH 操作接口：
- 远程命令执行（支持 sudo）
- 文件上传 / 下载
- 连接池管理
- 自动重试与超时控制
"""

import os
import time
import socket
from typing import Optional, Tuple, List
from contextlib import contextmanager

import paramiko

from common.exceptions import (
    SSHConnectionError,
    SSHAuthenticationError,
    SSHCommandError,
    SSHTimeoutError,
)
from common.logger import get_logger

logger = get_logger(__name__)


class SSHClient:
    """
    统一 SSH 客户端封装。

    用法:
        client = SSHClient("192.168.1.10", username="root")
        client.connect()
        exit_code, stdout, stderr = client.exec_command("hostname")
        client.close()
    """

    def __init__(
        self,
        host: str,
        username: str = "root",
        port: int = 22,
        password: str = None,
        key_file: str = None,
        timeout: int = 30,
        connect_retries: int = 3,
        retry_interval: int = 5,
    ):
        """
        初始化 SSH 客户端。

        Args:
            host: 目标主机 IP 或域名
            username: SSH 用户名
            port: SSH 端口
            password: 密码（密码认证时使用）
            key_file: 私钥文件路径（密钥认证时使用）
            timeout: 连接超时（秒）
            connect_retries: 连接重试次数
            retry_interval: 重试间隔（秒）
        """
        self.host = host
        self.username = username
        self.port = port
        self.password = password
        # 仅当未提供密码且未指定密钥时才使用默认密钥路径
        self.key_file = key_file if key_file else (
            None if password else os.path.expanduser("~/.ssh/id_rsa")
        )
        self.timeout = timeout
        self.connect_retries = connect_retries
        self.retry_interval = retry_interval

        self._client: Optional[paramiko.SSHClient] = None
        self._sftp: Optional[paramiko.SFTPClient] = None
        self._connected = False

    # ----- 连接管理 -----

    def connect(self) -> None:
        """建立 SSH 连接，支持自动重试。"""
        last_exception = None

        for attempt in range(1, self.connect_retries + 1):
            try:
                self._client = paramiko.SSHClient()
                self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

                connect_kwargs = {
                    "hostname": self.host,
                    "port": self.port,
                    "username": self.username,
                    "timeout": self.timeout,
                    "banner_timeout": self.timeout,
                }

                # 认证方式选择：
                # 1. 显式指定密码 → 优先密码认证
                # 2. 显式指定密钥 → 密钥认证
                # 3. 都未指定 → 尝试默认密钥 → 回退密码
                if self.password:
                    connect_kwargs["password"] = self.password
                elif self.key_file and os.path.exists(self.key_file):
                    connect_kwargs["key_filename"] = self.key_file
                elif os.path.exists(os.path.expanduser("~/.ssh/id_rsa")):
                    connect_kwargs["key_filename"] = os.path.expanduser("~/.ssh/id_rsa")

                self._client.connect(**connect_kwargs)
                self._connected = True

                # 开启 transport keepalive，防止长连接被中间设备断开
                transport = self._client.get_transport()
                if transport:
                    transport.set_keepalive(30)

                logger.debug(f"SSH 连接成功: {self.username}@{self.host}:{self.port}")
                return

            except paramiko.AuthenticationException as e:
                last_exception = SSHAuthenticationError(self.host, self.username)
                # 认证失败不重试
                raise last_exception

            except (paramiko.SSHException, socket.error, socket.timeout, EOFError) as e:
                last_exception = SSHConnectionError(
                    self.host, self.port, str(e)
                )
                logger.warning(
                    f"SSH 连接失败 (尝试 {attempt}/{self.connect_retries}): "
                    f"{self.host}:{self.port} — {e}"
                )
                if attempt < self.connect_retries:
                    time.sleep(self.retry_interval)
                # 清理失败的连接
                if self._client:
                    try:
                        self._client.close()
                    except Exception:
                        pass
                    self._client = None

        raise last_exception

    def close(self) -> None:
        """关闭 SSH 连接。"""
        if self._sftp:
            try:
                self._sftp.close()
            except Exception:
                pass
            self._sftp = None
        if self._client:
            try:
                self._client.close()
            except Exception:
                pass
            self._client = None
        self._connected = False
        logger.debug(f"SSH 连接已关闭: {self.host}")

    @property
    def is_connected(self) -> bool:
        """连接是否存活。"""
        if not self._connected or not self._client:
            return False
        try:
            transport = self._client.get_transport()
            if transport is None or not transport.is_active():
                return False
            return True
        except Exception:
            return False

    def ensure_connected(self) -> None:
        """确保连接存活，否则重新连接。"""
        if not self.is_connected:
            logger.info(f"SSH 连接已断开，尝试重新连接: {self.host}")
            self.connect()

    # ----- 命令执行 -----

    def exec_command(
        self,
        command: str,
        timeout: int = 600,
        sudo: bool = False,
        sudo_password: str = None,
        retry_on_failure: bool = True,
        max_retries: int = 3,
    ) -> Tuple[int, str, str]:
        """
        在远程主机上执行命令。

        Args:
            command: 要执行的命令
            timeout: 命令执行超时（秒）
            sudo: 是否通过 sudo 执行
            sudo_password: sudo 密码（None 则尝试 NOPASSWD）
            retry_on_failure: 失败时是否重试
            max_retries: 最大重试次数

        Returns:
            (exit_code, stdout, stderr) 三元组
        """
        self.ensure_connected()

        if sudo:
            if sudo_password:
                command = f"echo '{sudo_password}' | sudo -S {command}"
            else:
                command = f"sudo {command}"

        logger.debug(f"[{self.host}] 执行命令: {command[:200]}...")

        last_error = None
        for attempt in range(1, max_retries + 1):
            try:
                stdin, stdout, stderr = self._client.exec_command(command)
                # 设置 channel 超时，确保 recv_exit_status / read 不会永久阻塞
                channel = stdout.channel
                channel.settimeout(timeout)
                exit_code = channel.recv_exit_status()
                stdout_str = stdout.read().decode("utf-8", errors="replace").strip()
                stderr_str = stderr.read().decode("utf-8", errors="replace").strip()

                if exit_code != 0 and stderr_str:
                    logger.warning(
                        f"[{self.host}] 命令退出码={exit_code}, "
                        f"stderr={stderr_str[:200]}"
                    )

                return exit_code, stdout_str, stderr_str

            except (socket.timeout, paramiko.SSHException) as e:
                last_error = e
                logger.warning(
                    f"[{self.host}] 命令执行异常 (尝试 {attempt}/{max_retries}): {e}"
                )
                if retry_on_failure and attempt < max_retries:
                    time.sleep(5)
                    self.ensure_connected()
                else:
                    raise SSHTimeoutError(self.host, command) from e

        # 不应到达这里
        raise SSHCommandError(self.host, command, -1, str(last_error))

    def exec_command_ok(self, command: str, **kwargs) -> str:
        """
        执行命令并返回 stdout，非零退出码时抛出异常。
        适用于必须成功的命令场景。
        """
        exit_code, stdout, stderr = self.exec_command(command, **kwargs)
        if exit_code != 0:
            raise SSHCommandError(self.host, command, exit_code, stderr)
        return stdout

    # ----- 文件传输 -----

    def _get_sftp(self) -> paramiko.SFTPClient:
        """获取 SFTP 客户端（懒加载）。"""
        self.ensure_connected()
        if self._sftp is None:
            self._sftp = self._client.open_sftp()
        return self._sftp

    def upload_file(self, local_path: str, remote_path: str) -> None:
        """
        上传文件到远程主机。

        Args:
            local_path: 本地文件路径
            remote_path: 远程目标路径
        """
        if not os.path.isfile(local_path):
            raise FileNotFoundError(f"本地文件不存在: {local_path}")

        sftp = self._get_sftp()
        remote_dir = os.path.dirname(remote_path)
        if remote_dir:
            # 确保远程目录存在
            self.exec_command(f"mkdir -p {remote_dir}", sudo=True)

        logger.info(f"上传文件: {local_path} → {self.host}:{remote_path}")
        sftp.put(local_path, remote_path)
        logger.debug(f"上传完成: {remote_path}")

    def download_file(self, remote_path: str, local_path: str) -> None:
        """
        从远程主机下载文件。

        Args:
            remote_path: 远程文件路径
            local_path: 本地目标路径
        """
        local_dir = os.path.dirname(local_path)
        if local_dir:
            os.makedirs(local_dir, exist_ok=True)

        sftp = self._get_sftp()
        logger.info(f"下载文件: {self.host}:{remote_path} → {local_path}")
        sftp.get(remote_path, local_path)
        logger.debug(f"下载完成: {local_path}")

    def upload_directory(self, local_dir: str, remote_dir: str) -> None:
        """递归上传整个目录。"""
        self.exec_command(f"mkdir -p {remote_dir}", sudo=True)
        for root, dirs, files in os.walk(local_dir):
            rel_root = os.path.relpath(root, local_dir)
            remote_subdir = os.path.join(remote_dir, rel_root).replace("\\", "/")
            if rel_root != ".":
                self.exec_command(f"mkdir -p {remote_subdir}", sudo=True)
            for filename in files:
                local_file = os.path.join(root, filename)
                remote_file = os.path.join(remote_subdir, filename).replace("\\", "/")
                self.upload_file(local_file, remote_file)

    # ----- 便捷方法 -----

    def test_connection(self) -> bool:
        """测试连接是否可用。"""
        try:
            self.ensure_connected()
            exit_code, stdout, _ = self.exec_command("echo 'ok'", timeout=10)
            return exit_code == 0 and "ok" in stdout
        except Exception:
            return False

    def get_hostname(self) -> str:
        """获取远程主机名。"""
        _, stdout, _ = self.exec_command("hostname", timeout=5)
        return stdout.strip()

    def get_os_info(self) -> dict:
        """获取操作系统基本信息。"""
        info = {}
        _, info["hostname"], _ = self.exec_command("hostname", timeout=5)
        _, info["kernel"], _ = self.exec_command("uname -r", timeout=5)
        _, info["os_release"], _ = self.exec_command(
            "cat /etc/os-release 2>/dev/null | head -5", timeout=5
        )
        _, info["cpu_cores"], _ = self.exec_command("nproc", timeout=5)
        _, info["memory_mb"], _ = self.exec_command(
            "free -m | awk '/^Mem:/{print $2}'", timeout=5
        )
        _, info["disk_gb"], _ = self.exec_command(
            "df -BG / | awk 'NR==2{print $2}' | tr -d 'G'", timeout=5
        )
        return info

    # ----- 上下文管理器 -----

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def __repr__(self):
        return f"SSHClient(host={self.host}, user={self.username}, port={self.port})"
