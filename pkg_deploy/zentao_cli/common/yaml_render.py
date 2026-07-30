"""
YAML 配置读写与模板渲染工具
"""

import os
import copy
from typing import Any, Dict, List, Optional

import yaml


class YAMLHelper:
    """YAML 配置读写辅助类"""

    @staticmethod
    def load(file_path: str, raise_on_missing: bool = True) -> Optional[Dict]:
        if not os.path.isfile(file_path):
            if raise_on_missing:
                raise FileNotFoundError(f"配置文件未找到: {file_path}")
            return None
        with open(file_path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}

    @staticmethod
    def save(file_path: str, data: Dict) -> None:
        os.makedirs(os.path.dirname(file_path) or ".", exist_ok=True)
        with open(file_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False, indent=2)

    @staticmethod
    def deep_merge(base: Dict, override: Dict) -> Dict:
        result = copy.deepcopy(base)
        for key, value in override.items():
            if key in result and isinstance(result[key], dict) and isinstance(value, dict):
                result[key] = YAMLHelper.deep_merge(result[key], value)
            else:
                result[key] = copy.deepcopy(value)
        return result

    @staticmethod
    def get_value(config: Dict, path: str, default: Any = None) -> Any:
        keys = path.split(".")
        current = config
        for key in keys:
            if isinstance(current, dict) and key in current:
                current = current[key]
            else:
                return default
        return current

    @staticmethod
    def render_template(template_path: str, variables: Dict, output_path: str) -> None:
        """将 YAML 模板中的 ${VAR} 占位符替换为实际值后写出"""
        with open(template_path, "r", encoding="utf-8") as f:
            content = f.read()
        import re
        def replacer(match):
            var_name = match.group(1)
            return str(variables.get(var_name, match.group(0)))
        content = re.sub(r'\$\{(\w+)\}', replacer, content)
        os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)
