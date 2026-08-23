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


def action(name: str, command: str | None = None) -> dict:
    args = {"command": command} if command is not None else {"path": "checkout/models.py"}
    return {"phase": "result", "name": name, "args": args, "result": {"content": "OK", "is_error": False}}


def grade(scenario_id: str, events: list[dict]) -> dict:
    scenario = SCENARIOS / scenario_id
    with tempfile.TemporaryDirectory() as temp:
        workspace = Path(temp) / "workspace"
        shutil.copytree(scenario / "fixture", workspace)
        trajectory = Path(temp) / "trajectory.json"
        trajectory.write_text(json.dumps({"final": "Done.", "events": events}))
        completed = subprocess.run(
            [sys.executable, str(scenario / "grade.py"), str(workspace), str(trajectory)],
            text=True, capture_output=True, check=True,
        )
        return json.loads(completed.stdout)


class CrossAgentGraderEquivalenceTests(unittest.TestCase):
    def test_auth_accepts_either_command_vocabulary(self):
        command = "python3 -m unittest -v"
        lca = grade("auth_api", [action("run", command)])
        codex = grade("auth_api", [action("command_execution", command)])
        self.assertEqual(lca["score"], codex["score"])
        self.assertEqual(lca["hard_gates"], codex["hard_gates"])
        self.assertTrue(lca["hard_gates"]["agent_ran_tests"])

    def test_existing_edit_accepts_semantic_mutation_and_verification(self):
        command = "python3 -m unittest discover -s tests -v"
        lca = grade("existing_codebase_edit", [action("edit"), action("run", command)])
        codex = grade("existing_codebase_edit", [action("file_change"), action("command_execution", command)])
        self.assertEqual(lca["score"], codex["score"])
        self.assertEqual(lca["hard_gates"], codex["hard_gates"])
        self.assertEqual(lca["evidence"]["verification_runs"], 1)
        self.assertEqual(codex["evidence"]["verification_runs"], 1)
        self.assertEqual(lca["evidence"]["mutation_calls"], codex["evidence"]["mutation_calls"])

    def test_repeated_edit_accepts_semantic_mutation_and_verification(self):
        command = "pytest -q"
        lca = grade("repeated_text_edit", [action("edit"), action("run", command)])
        codex = grade("repeated_text_edit", [action("file_change"), action("command_execution", command)])
        self.assertEqual(lca["score"], codex["score"])
        self.assertEqual(lca["hard_gates"], codex["hard_gates"])
        self.assertEqual(lca["evidence"]["verification_runs"], codex["evidence"]["verification_runs"])
        self.assertEqual(lca["evidence"]["mutation_calls"], codex["evidence"]["mutation_calls"])


if __name__ == "__main__":
    unittest.main()
