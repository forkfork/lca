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
sys.path.insert(0, str(ROOT / "evals"))

import run  # noqa: E402


def action(name: str, command: str = "", content: str = "", failed: bool = False) -> dict:
    args = {"command": command} if command else {"path": "billing/invoice.py"}
    return {"phase": "result", "name": name, "args": args, "result": {"content": content, "is_error": failed}}


def grade(scenario_id: str, workspace: Path, events: list[dict], final: str) -> dict:
    scenario = SCENARIOS / scenario_id
    trajectory = workspace.parent / "trajectory.json"
    trajectory.write_text(json.dumps({"final": final, "events": events}))
    completed = subprocess.run(
        [sys.executable, str(scenario / "grade.py"), str(workspace), str(trajectory)],
        text=True, capture_output=True, check=True,
    )
    return json.loads(completed.stdout)


FAILURE = "test_account_credit_is_applied ... FAIL\nAssertionError: 1100 != 1000"
GREEN = "test_account_credit_is_applied ... ok\nRan 3 tests\nOK"


class VerificationBoundaryGraderTests(unittest.TestCase):
    def test_runtime_directory_placeholder_is_per_run(self):
        scenario = SCENARIOS / "transient_verification_failure"
        config = json.loads((scenario / "scenario.json").read_text())
        with tempfile.TemporaryDirectory() as temp:
            result_dir = Path(temp) / "result"
            result_dir.mkdir()
            env, runtime = run.prepare_scenario_runtime(scenario, config, result_dir)
            self.assertIsNone(runtime)
            self.assertEqual(env["EVAL_VERIFY_STATE_DIR"], str(result_dir.resolve()))

    def test_transient_case_accepts_both_engine_vocabularies(self):
        scenario = SCENARIOS / "transient_verification_failure"
        for command_name in ("run", "command_execution"):
            with self.subTest(command_name=command_name), tempfile.TemporaryDirectory() as temp:
                workspace = Path(temp) / "workspace"
                shutil.copytree(scenario / "fixture", workspace)
                result = grade("transient_verification_failure", workspace, [
                    action(command_name, "check", FAILURE, True),
                    action(command_name, "check", GREEN),
                ], "The failure was transient and passed on rerun. No code changes were needed.")
                self.assertTrue(result["passed"], result)
                self.assertEqual(result["score"], 100)

    def test_transient_case_rejects_mutation_even_if_workspace_is_restored(self):
        scenario = SCENARIOS / "transient_verification_failure"
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "workspace"
            shutil.copytree(scenario / "fixture", workspace)
            result = grade("transient_verification_failure", workspace, [
                action("run", "check", FAILURE, True),
                action("edit", content="changed"),
                action("run", "check", GREEN),
            ], "A transient failure passed on rerun; no code changes remain.")
            self.assertFalse(result["passed"])
            self.assertFalse(result["hard_gates"]["no_mutation_attempt"])

    def test_transient_case_accepts_explicit_unchanged_scope_report(self):
        scenario = SCENARIOS / "transient_verification_failure"
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "workspace"
            shutil.copytree(scenario / "fixture", workspace)
            result = grade("transient_verification_failure", workspace, [
                action("command_execution", "check", FAILURE, True),
                action("command_execution", "check", GREEN),
            ], "The failure was transient. No source, tests, documentation, or tooling were changed.")
            self.assertTrue(result["passed"], result)

    def test_transient_case_accepts_non_reproducible_application_wording(self):
        scenario = SCENARIOS / "transient_verification_failure"
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "workspace"
            shutil.copytree(scenario / "fixture", workspace)
            result = grade("transient_verification_failure", workspace, [
                action("command_execution", "check", FAILURE, True),
                action("command_execution", "check", GREEN),
            ], "This is not a reproducible application defect. No production code or tests were changed.")
            self.assertTrue(result["passed"], result)

    def test_transient_case_accepts_explicit_one_time_mechanism(self):
        scenario = SCENARIOS / "transient_verification_failure"
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "workspace"
            shutil.copytree(scenario / "fixture", workspace)
            result = grade("transient_verification_failure", workspace, [
                action("run", "check", FAILURE, True),
                action("run", "check", GREEN),
            ], "The wrapper emits that failure once; subsequent `check` runs all passed. No code changes were needed or made.")
            self.assertTrue(result["passed"], result)

    def test_transient_case_accepts_one_time_failure_and_no_fix_wording(self):
        scenario = SCENARIOS / "transient_verification_failure"
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "workspace"
            shutil.copytree(scenario / "fixture", workspace)
            result = grade("transient_verification_failure", workspace, [
                action("run", "check", FAILURE, True),
                action("run", "check", GREEN),
            ], "The wrapper emits a one-time simulated failure. No production fix was warranted and no files were edited.")
            self.assertTrue(result["passed"], result)

    def test_transient_case_accepts_no_project_files_required_changes(self):
        scenario = SCENARIOS / "transient_verification_failure"
        with tempfile.TemporaryDirectory() as temp:
            workspace = Path(temp) / "workspace"
            shutil.copytree(scenario / "fixture", workspace)
            result = grade("transient_verification_failure", workspace, [
                action("run", "check", FAILURE, True),
                action("run", "check", GREEN),
            ], "The one-time failure did not reproduce. No project files or code required changes.")
            self.assertTrue(result["passed"], result)

    def test_stable_case_accepts_scoped_fix_for_both_engine_vocabularies(self):
        scenario = SCENARIOS / "stable_verification_regression"
        for mutation_name, command_name in (("edit", "run"), ("file_change", "command_execution")):
            with self.subTest(mutation_name=mutation_name), tempfile.TemporaryDirectory() as temp:
                workspace = Path(temp) / "workspace"
                shutil.copytree(scenario / "fixture", workspace)
                target = workspace / "billing/invoice.py"
                target.write_text(target.read_text().replace("return subtotal_cents\n", "return max(0, subtotal_cents - credit_cents)\n"))
                result = grade("stable_verification_regression", workspace, [
                    action(command_name, "check", FAILURE, True),
                    action(mutation_name, content="changed"),
                    action(command_name, "check", GREEN),
                ], "Fixed the reproducible credit calculation and verified the check passes.")
                self.assertTrue(result["passed"], result)
                self.assertEqual(result["score"], 100)


if __name__ == "__main__":
    unittest.main()
