from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCENARIOS = ROOT / "evals/scenarios"


class GraderSmokeTests(unittest.TestCase):
    def test_noop_does_not_pass_mutating_scenarios(self):
        for scenario_id in (
            "ambiguous_bug_investigation", "auth_api", "batch_many_files",
            "context_boundary_edit", "credential_loader_bug", "existing_codebase_edit", "failure_recovery",
            "environment_recovery", "port_loader_bug", "repeated_text_edit", "stale_edit_recovery",
            "stable_verification_regression", "multifile_order_cancellation",
        ):
            with self.subTest(scenario=scenario_id), tempfile.TemporaryDirectory() as temp:
                scenario = SCENARIOS / scenario_id
                workspace = Path(temp) / "workspace"
                shutil.copytree(scenario / "fixture", workspace)
                trajectory = Path(temp) / "trajectory.json"
                trajectory.write_text(json.dumps({
                    "final": "Done.", "events": [], "tool_calls": 0, "llm_calls": 1,
                }))
                completed = subprocess.run(
                    [sys.executable, str(scenario / "grade.py"), str(workspace), str(trajectory)],
                    text=True, capture_output=True,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertFalse(json.loads(completed.stdout)["passed"])

    def test_noop_does_not_pass_transient_scenario_without_observed_recovery(self):
        scenario = SCENARIOS / "transient_verification_failure"
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "workspace"
            shutil.copytree(scenario / "fixture", workspace)
            trajectory = Path(temp) / "trajectory.json"
            trajectory.write_text(json.dumps({"final": "No changes needed.", "events": []}))
            completed = subprocess.run(
                [sys.executable, str(scenario / "grade.py"), str(workspace), str(trajectory)],
                text=True, capture_output=True, check=True,
            )
            self.assertFalse(json.loads(completed.stdout)["passed"])


if __name__ == "__main__":
    unittest.main()
