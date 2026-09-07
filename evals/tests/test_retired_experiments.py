import argparse
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run


class RetiredExperimentTests(unittest.TestCase):
    def test_retired_variants_fail_before_workspace_or_model_calls(self):
        variants = [{key: value} for key in (
            "delegate_readonly_enabled", "tool_dag_enabled", "readonly_fork_join_enabled"
        ) for value in (True, False)]
        variants += [{"delegate_readonly_profile": "compact_luna"}, {"edit_tool_profile": "exact"},
                     {"system_prompt_profile": "planning-clarity"}, {"system_prompt_profile": "workflow-lite"},
                     *({"system_prompt_profile": p} for p in ("repo-facts", "lean", "minimal")), {"engine": "wire_probe"}]
        for variant in variants:
            with self.subTest(variant=variant), patch.object(Path, "mkdir") as mkdir:
                with self.assertRaisesRegex(ValueError, "retired experiment option"):
                    run.run_once(Path("unused"), {}, argparse.Namespace(), 1,
                                 {"id": "retired", **variant})
                mkdir.assert_not_called()

    def test_current_variants_and_historical_manifests_remain_readable(self):
        run.validate_active_variant({"id": "current", "edit_tool_profile": "tagged"})
        self.assertIn("read_only_tool_dependency_dag", run.load_theories())

    def test_lua_driver_rejects_retired_switches_before_reading_inputs(self):
        root = Path(__file__).resolve().parents[2]
        for option, value in (("delegate-readonly-enabled", "true"),
                              ("delegate-readonly-profile", "compact_luna"),
                              ("tool-dag-enabled", "false"),
                              ("readonly-fork-join-enabled", "true"),
                              ("edit-tool-profile", "exact"),
                              ("system-prompt-profile", "planning-clarity"),
                              ("system-prompt-profile", "workflow-lite"),
                              ("system-prompt-profile", "repo-facts"),
                              ("system-prompt-profile", "lean"),
                              ("system-prompt-profile", "minimal")):
            result = subprocess.run([
                "lua5.5", str(root / "evals/driver.lua"), "--root", str(root),
                "--prompt-file", "missing", "--credentials", "missing",
                "--output", "unused", "--transcript", "unused", "--" + option, value,
            ], text=True, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("retired experiment option", result.stderr)
