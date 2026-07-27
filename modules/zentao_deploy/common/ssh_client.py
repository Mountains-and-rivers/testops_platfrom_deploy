"""
SSH 远程执行封装
用于编译服务器操作：源码拉取、镜像构建、环境配置
"""

import os
import time
import socket
from typing import Tuple, Optional

import paramiko

from common.log_utils import get_logger

logger = get_logger(__name__)


class SSHClient:
    """统一 SSH 客户端封装"""

    def __init__(self, host: str, username: str = "root", port: int = 22,
                 password: str = None, key_file: str = None,
                 timeout: int = 30, connect_retries: int = 3):
        self.host = host
        self.username = username
        self.port = port
        self.password = password
        self.key_file = key_file if key_file else (
            None if password else os.path.expanduser("~/.ssh/id_rsa"))
        self.timeout = timeout
        self.connect_retries = connect_retries
        self._client: Optional[paramiko.SSHClient] = None
        self._connected = False

    def connect(self) -> None:
        """建立 SSH 连接，支持自动重试"""
        last_exception = None
        for attempt in range(1, self.connect_retries + 1):
            try:
                self._client = paramiko.SSHClient()
                self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                kwargs = {"hostname": self.host, "port": self.port,
                          "username": self.username, "timeout": self.timeout,
                          "banner_timeout": self.timeout}
                if self.password:
                    kwargs["password"] = self.password
                elif self.key_file and os.path.exists(self.key_file):
                    kwargs["key_filename"] = self.key_file
                elif os.path.exists(os.path.expanduser("~/.ssh/id_rsa")):
                    kwargs["key_filename"] = os.path.expanduser("~/.ssh/id_rsa")

                self._client.connect(**kwargs)
                self._connected = True
                transport = self._client.get_transport()
                if transport:
                    transport.set_keepalive(30)
                logger.debug(f"SSH 连接成功: {self.username}@{self.host}:{self.port}")
                return
            except paramiko.AuthenticationException as e:
                raise RuntimeError(f"SSH 认证失败: {self.username}@{self.host}") from e
            except (paramiko.SSHException, socket.error, socket.timeout, EOFError) as e:
                last_exception = e
                logger.warning(f"SSH 连接失败 (尝试 {attempt}/{self.connect_retries}): {self.host}:{self.port}")
                if attempt < self.connect_retries:
                    time.sleep(5)
                if self._client:
                    try:
                        self._client.close()
                    except Exception:
                        pass
                    self._client = None
        raise RuntimeError(f"SSH 连接失败: {self.host}:{self.port} — {last_exception}")

    def close(self) -> None:
        """关闭连接"""
        if self._client:
            try:
                self._client.close()
            except Exception:
                pass
            self._client = None
        self._connected = False

    @property
    def is_connected(self) -> bool:
        if not self._connected or not self._client:
            return False
        try:
            transport = self._client.get_transport()
            return transport is not None and transport.is_active()
        except Exception:
            return False

    def exec_command(self, command: str, timeout: int = 600,
                     retry_on_failure: bool = True, max_retries: int = 3) -> Tuple[int, str, str]:
        """执行远程命令，返回 (exit_code, stdout, stderr)"""
        if not self.is_connected:
            self.connect()
        logger.debug(f"[{self.host}] 执行: {command[:200]}")
        for attempt in range(1, max_retries + 1):
            try:
                stdin, stdout, stderr = self._client.exec_command(command, timeout=timeout)
                exit_code = stdout.channel.recv_exit_status()
                out = stdout.read().decode("utf-8", errors="replace").strip()
                err = stderr.read().decode("utf-8", errors="replace").strip()
                if exit_code != 0 and err:
                    logger.warning(f"[{self.host}] exit={exit_code}, stderr={err[:200]}")
                return exit_code, out, err
            except (socket.timeout, paramiko.SSHException) as e:
                logger.warning(f"[{self.host}] 命令异常 (尝试 {attempt}/{max_retries}): {e}")
                if retry_on_failure and attempt < max_retries:
                    time.sleep(5)
                    if not self.is_connected:
                        self.connect()
                else:
                    raise RuntimeError(f"SSH 命令超时 [{self.host}]: {command[:100]}") from e
        return -1, "", str(last_error) if 'last_error' in dir() else "unknown"

    def exec_ok(self, command: str, **kwargs) -> str:
        """执行命令，成功返回 stdout，失败抛异常"""
        exit_code, stdout, stderr = self.exec_command(command, **kwargs)
        if exit_code != 0:
            raise RuntimeError(f"命令失败 [{self.host}]: {command[:100]} — {stderr[:200]}")
        return stdout

    def upload_file(self, local_path: str, remote_path: str) -> None:
        """上传文件到远程"""
        if not os.path.isfile(local_path):
            raise FileNotFoundError(f"文件不存在: {local_path}")
        if not self.is_connected:
            self.connect()
        sftp = self._client.open_sftp()
        remote_dir = os.path.dirname(remote_path)
        if remote_dir:
            self.exec_command(f"mkdir -p {remote_dir}")
        logger.info(f"上传: {local_path} → {self.host}:{remote_path}")
        sftp.put(local_path, remote_path)
        sftp.close()

    def download_file(self, remote_path: str, local_path: str) -> None:
        """从远程下载文件"""
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        if not self.is_connected:
            self.connect()
        sftp = self._client.open_sftp()
        logger.info(f"下载: {self.host}:{remote_path} → {local_path}")
        sftp.get(remote_path, local_path)
        sftp.close()

    def test_connection(self) -> bool:
        """测试连通性"""
        try:
            self.connect()
            exit_code, stdout, _ = self.exec_command("echo 'OK'", timeout=10)
            return exit_code == 0 and "OK" in stdout
        except Exception:
            return False

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *args):
        self.close()
        return False
