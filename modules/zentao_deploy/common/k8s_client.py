"""
Kubernetes SDK 统一封装
提供资源 apply、delete、status 等操作
"""

import os
import subprocess
import tempfile
from typing import Optional
from common.log_utils import get_logger

logger = get_logger(__name__)


class K8sClient:
    """Kubernetes kubectl 封装客户端"""

    def __init__(self, kubeconfig: str = None, namespace: str = "default"):
        self.kubeconfig = kubeconfig or os.environ.get("KUBECONFIG",
                                                       os.path.expanduser("~/.kube/config"))
        self.namespace = namespace

    def _kubectl(self, args: str, timeout: int = 120) -> subprocess.CompletedProcess:
        cmd = f"kubectl --kubeconfig={self.kubeconfig} {args}"
        logger.debug(f"kubectl: {cmd[:200]}")
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)

    def apply(self, yaml_path: str) -> bool:
        """apply YAML 资源"""
        result = self._kubectl(f"apply -f {yaml_path}")
        if result.returncode != 0:
            logger.error(f"kubectl apply 失败: {result.stderr[:300]}")
            return False
        logger.info(f"资源已 apply: {yaml_path}")
        return True

    def apply_text(self, yaml_text: str) -> bool:
        """apply YAML 文本"""
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
            f.write(yaml_text)
            tmp_path = f.name
        try:
            return self.apply(tmp_path)
        finally:
            os.unlink(tmp_path)

    def delete(self, yaml_path: str) -> bool:
        """删除资源"""
        result = self._kubectl(f"delete -f {yaml_path} --ignore-not-found=true")
        return result.returncode == 0

    def rollout_status(self, resource: str, name: str, namespace: str = None,
                       timeout: int = 120) -> bool:
        """等待滚动更新完成"""
        ns = namespace or self.namespace
        result = self._kubectl(f"rollout status {resource}/{name} -n {ns} --timeout={timeout}s",
                               timeout=timeout + 10)
        return result.returncode == 0

    def get_pods(self, label: str = None, namespace: str = None) -> str:
        """获取 Pod 列表"""
        ns = namespace or self.namespace
        label_arg = f"-l {label}" if label else ""
        result = self._kubectl(f"get pods -n {ns} {label_arg} --no-headers", timeout=30)
        return result.stdout.strip()

    def pod_ready(self, label: str, namespace: str = None, expected: int = 1) -> bool:
        """检查指定 label 的 Pod 是否全部 Ready"""
        ns = namespace or self.namespace
        result = self._kubectl(
            f"wait --for=condition=ready pod -l {label} -n {ns} --timeout=180s",
            timeout=200
        )
        return result.returncode == 0

    def namespace_exists(self, namespace: str) -> bool:
        result = self._kubectl(f"get ns {namespace} -o name", timeout=10)
        return result.returncode == 0

    def create_namespace(self, namespace: str) -> bool:
        if self.namespace_exists(namespace):
            return True
        result = self._kubectl(f"create ns {namespace}", timeout=10)
        return result.returncode == 0

    def resource_exists(self, resource_type: str, name: str, namespace: str = None) -> bool:
        ns = namespace or self.namespace
        result = self._kubectl(f"get {resource_type} {name} -n {ns} -o name", timeout=10)
        return result.returncode == 0
