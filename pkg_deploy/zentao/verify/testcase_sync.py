"""
禅道 OpenAPI 预留接口 — 用例/缺陷/任务同步
实现 CI/CD 流水线完成后自动上报测试结果到禅道

用法（预留，当前仅框架）:
    from pkg_deploy.zentao.verify.testcase_sync import sync_test_result
    sync_test_result(zentao_url, api_token, test_data)
"""

import os
import sys
from typing import Dict, List, Optional

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from common.log_utils import get_logger
from common.yaml_render import YAMLHelper

logger = get_logger(__name__)
CONFIG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "configs")


class ZentaoAPIError(Exception):
    """禅道 API 调用异常"""


class ZentaoAPIClient:
    """
    禅道 OpenAPI 客户端（预留框架）
    禅道 REST API 文档: https://www.zentao.net/book/zentaopmshelp/809.html
    """

    def __init__(self, base_url: str = None, token: str = None):
        config = YAMLHelper.load(os.path.join(CONFIG_DIR, "global.yaml")) if base_url is None else {}
        self.base_url = base_url or f"http://{config.get('kubernetes', {}).get('ingress_host', 'zentao.testops.local')}"
        self.token = token or os.environ.get("ZENTAO_API_TOKEN", "")
        self.api_prefix = f"{self.base_url}/api.php/v1"

    def _request(self, method: str, path: str, data: dict = None) -> dict:
        """HTTP 请求封装（预留实现）"""
        import urllib.request
        import json
        url = f"{self.api_prefix}{path}"
        headers = {"Content-Type": "application/json", "Token": self.token}
        req = urllib.request.Request(url, method=method, headers=headers)
        if data:
            req.data = json.dumps(data).encode("utf-8")
        try:
            resp = urllib.request.urlopen(req, timeout=30)
            return json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            raise ZentaoAPIError(f"API 请求失败: {e}")

    def create_bug(self, product_id: int, title: str, severity: int = 3,
                   steps: str = "", assigned_to: str = "") -> dict:
        """创建缺陷"""
        data = {"product": product_id, "title": title, "severity": severity,
                "steps": steps, "assignedTo": assigned_to}
        return self._request("POST", "/bugs", data)

    def create_testcase(self, product_id: int, module_id: int, title: str,
                        precondition: str = "", steps: list = None) -> dict:
        """创建测试用例"""
        data = {"product": product_id, "module": module_id, "title": title,
                "precondition": precondition, "steps": steps or []}
        return self._request("POST", "/testcases", data)

    def update_bug_status(self, bug_id: int, status: str = "resolved",
                          comment: str = "") -> dict:
        """更新缺陷状态"""
        return self._request("PUT", f"/bugs/{bug_id}", {"status": status, "comment": comment})


def sync_test_result(zentao_url: str, api_token: str, test_data: dict):
    """
    CI/CD 流水线调用入口：同步测试结果到禅道
    test_data 格式:
    {
        "product_id": 1,
        "title": "自动化测试发现缺陷 — 登录页面超时",
        "severity": 3,
        "steps": "1. 打开登录页\n2. 输入用户名密码\n3. 点击登录\n4. 页面响应超过5秒",
    }
    """
    client = ZentaoAPIClient(zentao_url, api_token)
    logger.info("同步测试结果到禅道...")
    try:
        result = client.create_bug(**test_data)
        logger.info(f"  缺陷已创建: ID={result.get('id', 'unknown')}")
        return result
    except ZentaoAPIError as e:
        logger.error(f"  同步失败: {e}")
        return None
