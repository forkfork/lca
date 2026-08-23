from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GRADER = ROOT / "evals/scenarios/simple_prompt/grade.py"
FIXTURE = ROOT / "evals/scenarios/simple_prompt/fixture"


def grade(answer: str, tool_calls: int = 0, llm_calls: int = 1) -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".json") as handle:
        json.dump({"final": answer, "tool_calls": tool_calls, "llm_calls": llm_calls}, handle)
        handle.flush()
        completed = subprocess.run(
            [sys.executable, str(GRADER), str(FIXTURE), handle.name],
            text=True, capture_output=True, check=True,
        )
    return json.loads(completed.stdout)


class SimplePromptGraderTests(unittest.TestCase):
    def test_bare_answer_passes(self):
        self.assertTrue(grade("391")["passed"])

    def test_brief_worked_answer_passes(self):
        self.assertTrue(grade("17 × 23 = 391.")["passed"])

    def test_wrong_answer_fails(self):
        self.assertFalse(grade("392")["passed"])

    def test_unnecessary_tool_or_second_model_call_fails(self):
        self.assertFalse(grade("391", tool_calls=1)["passed"])
        self.assertFalse(grade("391", llm_calls=2)["passed"])


if __name__ == "__main__":
    unittest.main()
