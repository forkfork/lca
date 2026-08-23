from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SUPPORT = (
    ROOT / "evals/scenarios/multifile_order_cancellation/grader_support.py"
)
spec = importlib.util.spec_from_file_location("order_cancellation_grader_support", SUPPORT)
grader_support = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(grader_support)


class MultifileOrderCancellationGraderTests(unittest.TestCase):
    def test_accepts_green_tests_before_trailing_git_failure(self):
        event = {
            "args": {"command": "python3 -m unittest discover -s tests && git diff"},
            "result": {
                "is_error": True,
                "content": "Ran 4 tests in 0.001s\n\nOK\nfatal: not a git repository\n",
            },
        }
        self.assertTrue(grader_support.successful_test_evidence(event))

    def test_rejects_failed_or_absent_test_evidence(self):
        failed = {
            "args": {"command": "python3 -m unittest discover -s tests"},
            "result": {"is_error": True, "content": "Ran 4 tests\nFAILED (failures=1)\n"},
        }
        unrelated = {
            "args": {"command": "git diff"},
            "result": {"is_error": False, "content": ""},
        }
        self.assertFalse(grader_support.successful_test_evidence(failed))
        self.assertFalse(grader_support.successful_test_evidence(unrelated))

    def test_fixture_explicitly_defines_trimmed_identity(self):
        readme = (SUPPORT.parent / "fixture/README.md").read_text()
        self.assertIn("Trim it before storing or comparing it", readme)


if __name__ == "__main__":
    unittest.main()
