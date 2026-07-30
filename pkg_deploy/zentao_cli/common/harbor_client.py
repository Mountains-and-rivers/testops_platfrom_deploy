"""
Harbor 镜像仓库 API 封装
支持镜像查询、Tag 列表、镜像存在性检查
"""

import requests
from typing import List, Optional
from common.log_utils import get_logger

logger = get_logger(__name__)


class HarborClient:
    """Harbor v2 API 客户端"""

    def __init__(self, base_url: str, username: str, password: str):
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.session = requests.Session()
        self.session.auth = (username, password)
        self.session.headers.update({"Accept": "application/json"})

    def check_health(self) -> bool:
        """检查 Harbor 是否可达"""
        try:
            resp = self.session.get(f"{self.base_url}/api/v2.0/health", timeout=10)
            return resp.status_code == 200
        except Exception as e:
            logger.warning(f"Harbor 健康检查失败: {e}")
            return False

    def project_exists(self, project_name: str) -> bool:
        """检查项目是否存在"""
        try:
            resp = self.session.get(f"{self.base_url}/api/v2.0/projects/{project_name}", timeout=10)
            return resp.status_code == 200
        except Exception:
            return False

    def create_project(self, project_name: str, public: bool = True) -> bool:
        """创建项目（如不存在）"""
        if self.project_exists(project_name):
            return True
        try:
            payload = {
                "project_name": project_name,
                "public": public,
                "metadata": {"public": str(public).lower()}
            }
            resp = self.session.post(f"{self.base_url}/api/v2.0/projects", json=payload, timeout=15)
            if resp.status_code in (200, 201):
                logger.info(f"Harbor 项目已创建: {project_name}")
                return True
            logger.error(f"Harbor 创建项目失败: {resp.status_code} {resp.text[:200]}")
            return False
        except Exception as e:
            logger.error(f"Harbor 创建项目异常: {e}")
            return False

    def image_exists(self, project: str, image: str, tag: str = "latest") -> bool:
        """检查镜像 Tag 是否存在"""
        try:
            resp = self.session.get(
                f"{self.base_url}/api/v2.0/projects/{project}/repositories/{image}/artifacts/{tag}",
                timeout=10
            )
            return resp.status_code == 200
        except Exception:
            return False
