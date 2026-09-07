import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lesson_gate
import cache_lesson_grader
import campaign

SCENARIOS = Path(__file__).resolve().parents[1] / "scenarios"
VERIFIED = {"events": [{"name": "run", "args": {"command": "python3 -m unittest discover -s tests -v"},
                         "result": {"is_error": False, "content": "Ran 3 tests\nOK"}}]}


class LessonGateTests(unittest.TestCase):
    def test_applicability_matrix(self):
        for task, applicable in (("lesson_cache_valid", True), ("lesson_cache_stale", False), ("simple_prompt", False)):
            for policy in ("none", "advisory", "checked"):
                actual = lesson_gate.load(policy, task)
                self.assertEqual(actual["applicable"], applicable)
                self.assertEqual(actual["injected"], policy == "advisory" or policy == "checked" and applicable)
                self.assertEqual(bool(actual["text"]), actual["injected"])
        with self.assertRaises(ValueError):
            lesson_gate.load("made-up", "simple_prompt")

    def grade(self, task, implementation=None, extra=False, verified=True):
        fixture = SCENARIOS / task / "fixture"
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp) / "workspace"
            shutil.copytree(fixture, workspace)
            if implementation:
                (workspace / "analyzer.py").write_text(implementation)
            if extra:
                (workspace / "unexpected.txt").write_text("scope violation")
            return cache_lesson_grader.grade(fixture, workspace, VERIFIED if verified else {"events": []})

    def fix(self, contextual, wrong=False):
        key = "(path, text)" if contextual and not wrong else "text"
        invocation = "parser(path, text)" if contextual else "parser(text)"
        return f'''def analyze(files, parser):
    cache = {{}}
    output = []
    for path, text in files:
        key = {key}
        if key not in cache:
            cache[key] = {invocation}
        output.append((path, cache[key]))
    return output
'''

    def test_known_good_and_bad_artifacts(self):
        for contextual, task in ((False, "lesson_cache_valid"), (True, "lesson_cache_stale")):
            self.assertFalse(self.grade(task)["passed"])
            self.assertTrue(self.grade(task, self.fix(contextual))["passed"])
            self.assertFalse(self.grade(task, self.fix(contextual), extra=True)["passed"])
            self.assertFalse(self.grade(task, self.fix(contextual), verified=False)["passed"])
        self.assertFalse(self.grade("lesson_cache_stale", self.fix(True, wrong=True))["hard_gates"]["public_tests"])

    def test_audit_detects_wrong_lesson_injection(self):
        for task in ("simple_prompt", "lesson_cache_valid", "lesson_cache_stale"):
            for policy in ("none", "advisory", "checked"):
                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    cell = {"scenario": task, "variant": {"model": "gpt-6-astra", "reasoning": "high", "lesson_policy": policy}}
                    expected = lesson_gate.load(policy, task)
                    campaign.save(root / "result.json", {"passed": True, "metrics": {"estimated_total_api_cost_usd": .1}})
                    campaign.save(root / "run-config.json", {"model": "gpt-6-astra", "reasoning": "high"})
                    campaign.save(root / "trajectory.json", {"context_pilot": {"mode": "normal", "requests": 1, "responses": 1}, "usage": [{}]})
                    campaign.save(root / "lesson-policy.json", expected)
                    request = {"model": "gpt-6-astra", "reasoning_effort": "high", "context_mode": "normal",
                               "messages": [{"role": "user", "text": expected["text"]}] if expected["text"] else []}
                    campaign.save(root / "request-0001.json", request)
                    self.assertTrue(campaign.inspect_result(root, cell)["passed"])
                    request["messages"] = [{"role": "user", "text": lesson_gate.PREFIX + "WRONG"}]
                    campaign.save(root / "request-0001.json", request)
                    with self.assertRaisesRegex(ValueError, "injection"):
                        campaign.inspect_result(root, cell)


if __name__ == "__main__":
    unittest.main()
