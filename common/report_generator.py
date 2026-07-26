"""
标准化报告生成工具。

提供：
- 执行摘要生成
- 详细报告生成（JSON / YAML / 纯文本）
- 多组件报告合并
- 报告模板渲染（Jinja2）
"""

import os
import json
import time
from datetime import datetime
from typing import Any, Dict, List, Optional

import yaml

from common.logger import get_logger

logger = get_logger(__name__)


class ReportSection:
    """报告中的一个章节。"""

    def __init__(self, title: str, level: int = 1):
        self.title = title
        self.level = level
        self.content: List[str] = []
        self.subsections: List["ReportSection"] = []
        self.metadata: Dict[str, Any] = {}

    def add_line(self, line: str):
        self.content.append(line)
        return self

    def add_lines(self, lines: List[str]):
        self.content.extend(lines)
        return self

    def add_subsection(self, title: str, level: int = None) -> "ReportSection":
        sub = ReportSection(title, level or self.level + 1)
        self.subsections.append(sub)
        return sub

    def to_text(self) -> str:
        """渲染为纯文本格式。"""
        indent = "  " * (self.level - 1)
        prefix_map = {1: "=", 2: "-", 3: "~", 4: "."}
        prefix = prefix_map.get(self.level, "-")
        lines = [
            f"{indent}{prefix * 4} {self.title} {prefix * 4}",
            ""
        ]
        if self.content:
            lines.extend(f"{indent}{line}" for line in self.content)
            lines.append("")
        for sub in self.subsections:
            lines.append(sub.to_text())
        return "\n".join(lines)

    def to_dict(self) -> Dict:
        """渲染为字典结构。"""
        return {
            "title": self.title,
            "level": self.level,
            "content": self.content,
            "metadata": self.metadata,
            "subsections": [s.to_dict() for s in self.subsections],
        }


class ReportGenerator:
    """
    标准化报告生成器。

    用法:
        gen = ReportGenerator("K8s 集群部署报告")
        section = gen.add_section("预检结果")
        section.add_line("✓ 所有节点 SSH 连接正常")
        section.add_line("✓ 系统版本符合要求")
        gen.save_text("/path/to/report.txt")
    """

    def __init__(self, title: str, component: str = ""):
        self.title = title
        self.component = component
        self.generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        self.root = ReportSection(title)
        self.sections: List[ReportSection] = []
        self.summary: Dict[str, Any] = {
            "status": "unknown",       # success | partial | failed
            "total_stages": 0,
            "passed": 0,
            "failed": 0,
            "skipped": 0,
            "warnings": 0,
        }

    def add_section(self, title: str) -> ReportSection:
        """添加一个报告章节。"""
        section = ReportSection(title)
        self.sections.append(section)
        return section

    def set_summary(self, **kwargs):
        """更新摘要信息。"""
        self.summary.update(kwargs)

    def add_task_result(self, task_result):
        """从 TaskResult 对象自动生成报告章节。"""
        section = self.add_section(task_result.task_name)
        section.metadata["status"] = task_result.status.value
        section.metadata["elapsed_seconds"] = task_result.elapsed_seconds
        section.add_line(f"状态: {task_result.status.value}")
        section.add_line(f"耗时: {task_result.elapsed_seconds:.1f}s")
        if task_result.error:
            section.add_line(f"错误: {task_result.error}")
        if task_result.messages:
            for msg in task_result.messages:
                section.add_line(f"  - {msg}")
        if task_result.data:
            section.add_line(f"数据: {json.dumps(task_result.data, ensure_ascii=False)}")
        return section

    # ----- 输出格式 -----

    def to_text(self) -> str:
        """生成纯文本格式报告。"""
        lines = [
            f"{'=' * 60}",
            f"  {self.title}",
            f"  组件: {self.component}",
            f"  生成时间: {self.generated_at}",
            f"{'=' * 60}",
            "",
            f"[摘要] 状态={self.summary['status']}, "
            f"通过={self.summary['passed']}/{self.summary['total_stages']}",
            "",
        ]
        for section in self.sections:
            lines.append(section.to_text())
        return "\n".join(lines)

    def to_dict(self) -> Dict:
        """生成字典结构（可序列化为 JSON/YAML）。"""
        return {
            "title": self.title,
            "component": self.component,
            "generated_at": self.generated_at,
            "summary": self.summary,
            "sections": [s.to_dict() for s in self.sections],
        }

    def to_json(self, indent: int = 2) -> str:
        """生成 JSON 格式报告。"""
        return json.dumps(self.to_dict(), ensure_ascii=False, indent=indent)

    def to_yaml(self) -> str:
        """生成 YAML 格式报告。"""
        return yaml.safe_dump(
            self.to_dict(), allow_unicode=True, sort_keys=False, indent=2
        )

    # ----- 文件输出 -----

    def save_text(self, file_path: str) -> None:
        """保存为纯文本报告。"""
        os.makedirs(os.path.dirname(file_path) or ".", exist_ok=True)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(self.to_text())
        logger.info(f"文本报告已保存: {file_path}")

    def save_json(self, file_path: str) -> None:
        """保存为 JSON 报告。"""
        os.makedirs(os.path.dirname(file_path) or ".", exist_ok=True)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(self.to_json())
        logger.info(f"JSON 报告已保存: {file_path}")

    def save_yaml(self, file_path: str) -> None:
        """保存为 YAML 报告。"""
        os.makedirs(os.path.dirname(file_path) or ".", exist_ok=True)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(self.to_yaml())
        logger.info(f"YAML 报告已保存: {file_path}")

    # ----- 静态工具方法 -----

    @staticmethod
    def merge_reports(reports: List["ReportGenerator"], title: str = "汇总报告") -> "ReportGenerator":
        """合并多个组件报告为一个汇总报告。"""
        merged = ReportGenerator(title=title)
        for report in reports:
            merged.sections.extend(report.sections)
            # 汇总统计
            merged.summary["total_stages"] += report.summary["total_stages"]
            merged.summary["passed"] += report.summary["passed"]
            merged.summary["failed"] += report.summary["failed"]
            merged.summary["skipped"] += report.summary["skipped"]
            merged.summary["warnings"] += report.summary["warnings"]

        if merged.summary["failed"] > 0:
            merged.summary["status"] = "partial"
        else:
            merged.summary["status"] = "success"

        return merged
