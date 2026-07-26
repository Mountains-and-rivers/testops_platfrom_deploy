"""
YAML 配置读写工具。

提供：
- YAML 文件的读取、写入
- 深合并（Deep Merge）多个 YAML 配置
- 配置路径点号分隔取值（如 "a.b.c"）
- 变量插值替换（${VAR} 模式）
"""

import os
import re
import copy
from typing import Any, Dict, List, Optional, Union

import yaml

from common.exceptions import ConfigNotFoundError, ConfigParseError


class YAMLHelper:
    """YAML 配置文件读写辅助类。"""

    @staticmethod
    def load(file_path: str, raise_on_missing: bool = True) -> Optional[Dict]:
        """
        加载单个 YAML 文件。

        Args:
            file_path: YAML 文件路径
            raise_on_missing: 文件不存在时是否抛出异常

        Returns:
            解析后的字典，文件不存在且 raise_on_missing=False 时返回 None
        """
        if not os.path.isfile(file_path):
            if raise_on_missing:
                raise ConfigNotFoundError(file_path)
            return None

        try:
            with open(file_path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
            return data if data is not None else {}
        except yaml.YAMLError as e:
            raise ConfigParseError(file_path, str(e))

    @staticmethod
    def load_all(file_paths: List[str]) -> Dict:
        """
        按顺序加载多个 YAML 文件并深度合并。

        Args:
            file_paths: YAML 文件路径列表

        Returns:
            深度合并后的配置字典
        """
        merged = {}
        for path in file_paths:
            data = YAMLHelper.load(path, raise_on_missing=True)
            if data:
                merged = YAMLHelper.deep_merge(merged, data)
        return merged

    @staticmethod
    def save(file_path: str, data: Dict, create_dirs: bool = True) -> None:
        """
        保存数据到 YAML 文件。

        Args:
            file_path: 目标文件路径
            data: 要保存的字典数据
            create_dirs: 是否自动创建父目录
        """
        if create_dirs:
            os.makedirs(os.path.dirname(file_path) or ".", exist_ok=True)

        with open(file_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(
                data,
                f,
                default_flow_style=False,
                allow_unicode=True,
                sort_keys=False,
                indent=2,
            )

    @staticmethod
    def deep_merge(base: Dict, override: Dict) -> Dict:
        """
        深度合并两个字典。

        规则：
        - 双方都有且都是 dict → 递归合并
        - override 中有，base 中无 → 使用 override 值
        - base 中有，override 中无 → 保留 base 值
        - 双方都有且不是都是 dict → override 覆盖 base
        - 列表类型直接覆盖（不做合并）
        """
        result = copy.deepcopy(base)
        for key, value in override.items():
            if key in result:
                if isinstance(result[key], dict) and isinstance(value, dict):
                    result[key] = YAMLHelper.deep_merge(result[key], value)
                else:
                    result[key] = copy.deepcopy(value)
            else:
                result[key] = copy.deepcopy(value)
        return result

    @staticmethod
    def get_value(config: Dict, path: str, default: Any = None) -> Any:
        """
        通过点号分隔的路径获取配置值。

        示例:
            get_value(config, "ssh.connection.timeout", 30)
        """
        keys = path.split(".")
        current = config
        for key in keys:
            if isinstance(current, dict) and key in current:
                current = current[key]
            else:
                return default
        return current

    @staticmethod
    def set_value(config: Dict, path: str, value: Any) -> None:
        """
        通过点号分隔的路径设置配置值，自动创建中间节点。

        示例:
            set_value(config, "ssh.connection.timeout", 60)
        """
        keys = path.split(".")
        current = config
        for key in keys[:-1]:
            if key not in current or not isinstance(current[key], dict):
                current[key] = {}
            current = current[key]
        current[keys[-1]] = value

    @staticmethod
    def interpolate_env_vars(config: Dict) -> Dict:
        """
        递归替换配置中的 ${ENV_VAR} 环境变量占位符。

        只替换叶子节点（字符串类型）中的变量。
        """
        pattern = re.compile(r"\$\{(\w+)\}")

        def _resolve(value):
            if isinstance(value, str):
                def replacer(match):
                    var_name = match.group(1)
                    return os.environ.get(var_name, match.group(0))
                return pattern.sub(replacer, value)
            elif isinstance(value, dict):
                return {k: _resolve(v) for k, v in value.items()}
            elif isinstance(value, list):
                return [_resolve(item) for item in value]
            return value

        return _resolve(copy.deepcopy(config))
