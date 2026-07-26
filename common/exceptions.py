"""
全局自定义异常类定义。

所有部署模块统一使用此异常体系，确保错误处理行为一致。
"""


class TestOpsException(Exception):
    """TestOps 平台基础异常，所有自定义异常的父类。"""

    def __init__(self, message: str = "", code: str = "UNKNOWN", details: dict = None):
        super().__init__(message)
        self.message = message
        self.code = code
        self.details = details or {}

    def __str__(self):
        base = f"[{self.code}] {self.message}"
        if self.details:
            base += f" | details: {self.details}"
        return base


# ============================================================
# 配置异常
# ============================================================
class ConfigError(TestOpsException):
    """配置相关异常。"""
    def __init__(self, message: str = "", code: str = "CONFIG_ERROR", details: dict = None):
        super().__init__(message, code, details)


class ConfigNotFoundError(ConfigError):
    """配置文件不存在。"""
    def __init__(self, config_path: str):
        super().__init__(
            message=f"配置文件未找到: {config_path}",
            code="CONFIG_NOT_FOUND",
            details={"config_path": config_path}
        )


class ConfigParseError(ConfigError):
    """配置文件解析失败。"""
    def __init__(self, config_path: str, reason: str = ""):
        super().__init__(
            message=f"配置文件解析失败: {config_path}" + (f" — {reason}" if reason else ""),
            code="CONFIG_PARSE_ERROR",
            details={"config_path": config_path, "reason": reason}
        )


class ConfigValidationError(ConfigError):
    """配置校验不通过。"""
    def __init__(self, config_path: str, errors: list = None):
        super().__init__(
            message=f"配置校验失败: {config_path}",
            code="CONFIG_VALIDATION_ERROR",
            details={"config_path": config_path, "errors": errors or []}
        )


# ============================================================
# SSH 异常
# ============================================================
class SSHException(TestOpsException):
    """SSH 相关异常基类。"""
    def __init__(self, message: str = "", code: str = "SSH_ERROR", details: dict = None):
        super().__init__(message, code, details)


class SSHConnectionError(SSHException):
    """SSH 连接失败。"""
    def __init__(self, host: str, port: int = 22, reason: str = ""):
        super().__init__(
            message=f"SSH 连接失败: {host}:{port}" + (f" — {reason}" if reason else ""),
            code="SSH_CONNECTION_ERROR",
            details={"host": host, "port": port, "reason": reason}
        )


class SSHAuthenticationError(SSHException):
    """SSH 认证失败。"""
    def __init__(self, host: str, username: str):
        super().__init__(
            message=f"SSH 认证失败: {username}@{host}",
            code="SSH_AUTH_ERROR",
            details={"host": host, "username": username}
        )


class SSHCommandError(SSHException):
    """SSH 远程命令执行失败。"""
    def __init__(self, host: str, command: str, exit_code: int, stderr: str = ""):
        super().__init__(
            message=f"SSH 命令执行失败 [{host}]: exit_code={exit_code}",
            code="SSH_COMMAND_ERROR",
            details={"host": host, "command": command, "exit_code": exit_code, "stderr": stderr}
        )


class SSHTimeoutError(SSHException):
    """SSH 操作超时。"""
    def __init__(self, host: str, operation: str = "unknown"):
        super().__init__(
            message=f"SSH 操作超时 [{host}]: {operation}",
            code="SSH_TIMEOUT_ERROR",
            details={"host": host, "operation": operation}
        )


# ============================================================
# 工作流异常
# ============================================================
class WorkflowException(TestOpsException):
    """工作流相关异常基类。"""
    def __init__(self, message: str = "", code: str = "WORKFLOW_ERROR", details: dict = None):
        super().__init__(message, code, details)


class StageFailedError(WorkflowException):
    """工作流阶段执行失败。"""
    def __init__(self, stage_name: str, component: str = "", reason: str = ""):
        super().__init__(
            message=f"阶段执行失败: {stage_name}" + (f" ({component})" if component else ""),
            code="STAGE_FAILED",
            details={"stage": stage_name, "component": component, "reason": reason}
        )


class StageSkippedError(WorkflowException):
    """工作流阶段被跳过（如已安装时跳过安装阶段）。"""
    def __init__(self, stage_name: str, skip_reason: str = ""):
        super().__init__(
            message=f"阶段已跳过: {stage_name}" + (f" — {skip_reason}" if skip_reason else ""),
            code="STAGE_SKIPPED",
            details={"stage": stage_name, "reason": skip_reason}
        )


class RollbackError(WorkflowException):
    """回滚操作失败。"""
    def __init__(self, stage_name: str, original_error: str = ""):
        super().__init__(
            message=f"回滚失败 [{stage_name}]" + (f", 原始错误: {original_error}" if original_error else ""),
            code="ROLLBACK_ERROR",
            details={"stage": stage_name, "original_error": original_error}
        )


# ============================================================
# 校验异常
# ============================================================
class PreCheckError(TestOpsException):
    """环境预检不通过。"""
    def __init__(self, checks_failed: list = None, message: str = ""):
        super().__init__(
            message=message or "环境预检未通过",
            code="PRECHECK_FAILED",
            details={"failed_checks": checks_failed or []}
        )


class DependencyError(TestOpsException):
    """依赖检查失败（如前置组件未安装）。"""
    def __init__(self, dependency: str, required_by: str = ""):
        super().__init__(
            message=f"依赖未满足: {dependency}" + (f" (被 {required_by} 依赖)" if required_by else ""),
            code="DEPENDENCY_ERROR",
            details={"dependency": dependency, "required_by": required_by}
        )
