"""
K8s Cluster Deploy — 模块内部自定义阶段异常
"""

from common.exceptions import WorkflowException


class K8sStageError(WorkflowException):
    """K8s 部署阶段执行错误基类。"""
    pass


class PreCheckFailedError(K8sStageError):
    """环境预检失败。"""
    def __init__(self, node: str, check_item: str, detail: str = ""):
        super().__init__(
            message=f"预检失败 [{node}] {check_item}: {detail}",
            code="K8S_PRECHECK_FAILED",
            details={"node": node, "check_item": check_item, "detail": detail}
        )


class SystemInitError(K8sStageError):
    """系统初始化失败。"""
    def __init__(self, node: str, operation: str, detail: str = ""):
        super().__init__(
            message=f"系统初始化失败 [{node}] {operation}: {detail}",
            code="K8S_SYS_INIT_FAILED",
            details={"node": node, "operation": operation, "detail": detail}
        )


class ContainerdSetupError(K8sStageError):
    """容器运行时安装失败。"""
    def __init__(self, node: str, detail: str = ""):
        super().__init__(
            message=f"容器运行时安装失败 [{node}]: {detail}",
            code="K8S_CONTAINERD_SETUP_FAILED",
            details={"node": node, "detail": detail}
        )


class KubeComponentInstallError(K8sStageError):
    """K8s 组件安装失败。"""
    def __init__(self, node: str, component: str, detail: str = ""):
        super().__init__(
            message=f"K8s 组件安装失败 [{node}] {component}: {detail}",
            code="K8S_COMPONENT_INSTALL_FAILED",
            details={"node": node, "component": component, "detail": detail}
        )


class MasterInitError(K8sStageError):
    """Master 节点初始化失败。"""
    def __init__(self, node: str, detail: str = ""):
        super().__init__(
            message=f"Master 初始化失败 [{node}]: {detail}",
            code="K8S_MASTER_INIT_FAILED",
            details={"node": node, "detail": detail}
        )


class NodeJoinError(K8sStageError):
    """节点加入集群失败。"""
    def __init__(self, node: str, detail: str = ""):
        super().__init__(
            message=f"节点加入集群失败 [{node}]: {detail}",
            code="K8S_NODE_JOIN_FAILED",
            details={"node": node, "detail": detail}
        )


class CNIDeployError(K8sStageError):
    """CNI 网络插件部署失败。"""
    def __init__(self, plugin: str, detail: str = ""):
        super().__init__(
            message=f"CNI 网络插件部署失败 [{plugin}]: {detail}",
            code="K8S_CNI_DEPLOY_FAILED",
            details={"plugin": plugin, "detail": detail}
        )


class ClusterVerifyError(K8sStageError):
    """集群健康校验不通过。"""
    def __init__(self, check_item: str, detail: str = ""):
        super().__init__(
            message=f"集群健康校验失败 [{check_item}]: {detail}",
            code="K8S_CLUSTER_VERIFY_FAILED",
            details={"check_item": check_item, "detail": detail}
        )


class TokenExpiredError(K8sStageError):
    """Join Token 已过期。"""
    def __init__(self):
        super().__init__(
            message="Join Token 已过期，请在 Master 节点重新生成",
            code="K8S_TOKEN_EXPIRED",
        )
