from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCENARIO = ROOT / "evals/scenarios/ambiguous_bug_investigation"


def grade(workspace: Path, trajectory: dict) -> dict:
    trajectory_path = workspace.parent / "trajectory.json"
    trajectory_path.write_text(json.dumps(trajectory))
    completed = subprocess.run(
        [sys.executable, str(SCENARIO / "grade.py"), str(workspace), str(trajectory_path)],
        text=True, capture_output=True, check=True,
    )
    return json.loads(completed.stdout)


class AmbiguousInvestigationGraderTests(unittest.TestCase):
    def test_shell_based_semantic_trace_is_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "workspace"
            shutil.copytree(SCENARIO / "fixture", workspace)
            cache = workspace / "checkout/cache.py"
            cache.write_text(cache.read_text().replace(
                "def key(items: list[LineItem]) -> tuple:\n"
                "        return tuple((item.sku, item.unit_price_cents, item.quantity) for item in items)",
                "def key(items: list[LineItem], discount_percent: int = 0) -> tuple:\n"
                "        return (discount_percent, tuple((item.sku, item.unit_price_cents, item.quantity) for item in items))",
            ))
            service = workspace / "checkout/service.py"
            service.write_text(service.read_text().replace(
                "        key = self.cache.key(items)\n",
                "        percent = discount_percent(customer)\n"
                "        key = self.cache.key(items, percent)\n",
            ).replace("        percent = discount_percent(customer)\n        total =", "        total ="))
            source_output = "\n".join(
                (SCENARIO / "fixture" / path).read_text()
                for path in ("checkout/service.py", "checkout/cache.py", "checkout/discounts.py")
            )
            events = [
                {
                    "name": "command_execution", "args": {"command": "sed -n '1,240p' checkout/*.py"},
                    "result": {"content": source_output, "is_error": False},
                },
                {
                    "name": "command_execution", "args": {"command": "python3 -m unittest discover -s tests -v"},
                    "result": {"content": "FAIL: test_vip_quote_after_regular_same_cart", "is_error": True},
                },
                {
                    "name": "file_change", "args": {"paths": ["checkout/cache.py", "checkout/service.py"]},
                    "result": {"content": "changed", "is_error": False},
                },
                {
                    "name": "command_execution", "args": {"command": "python3 -m unittest discover -s tests -v"},
                    "result": {"content": "OK", "is_error": False},
                },
            ]
            result = grade(workspace, {"final": "Fixed and verified.", "events": events})
            self.assertTrue(result["passed"], result)
            self.assertTrue(result["hard_gates"]["traced_pricing_path_before_edit"])


if __name__ == "__main__":
    unittest.main()
