import copy
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from operational_screen import COMMAND, audit, grade

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "evals/scenarios/compaction_stale_pass/fixture"


class OperationalScreenTests(unittest.TestCase):
    def test_artifact_and_submitted_version_grading(self):
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp) / "workspace"
            shutil.copytree(FIXTURE, workspace)
            correct = (workspace / "invoice.py").read_bytes()
            event = {"name": "run", "phase": "finish", "args": {"command": COMMAND},
                     "result": {"is_error": False, "content": "Ran 3 tests in 0.001s\n\nOK\n"},
                     "workspace_sha256": hashlib.sha256(correct).hexdigest()}
            self.assertTrue(grade(workspace, {"events": [event]}, FIXTURE)["passed"])
            self.assertFalse(grade(workspace, {"events": []}, FIXTURE)["passed"])
            wrong_hash = copy.deepcopy(event); wrong_hash["workspace_sha256"] = "old-version"
            self.assertFalse(grade(workspace, {"events": [wrong_hash]}, FIXTURE)["passed"])
            failed = copy.deepcopy(event); failed["result"]["is_error"] = True
            self.assertFalse(grade(workspace, {"events": [failed]}, FIXTURE)["passed"])
            fake = copy.deepcopy(event); fake["args"]["command"] = "printf 'Ran 3 tests\nOK'"
            self.assertFalse(grade(workspace, {"events": [fake]}, FIXTURE)["passed"])
            (workspace / "invoice.py").write_bytes(correct.replace(b"subtotal +", b"subtotal -"))
            broken = grade(workspace, {"events": [event]}, FIXTURE)
            self.assertFalse(broken["hard_gates"]["artifact_correct"])
            self.assertFalse(broken["hard_gates"]["verified_submitted_version"])
            (workspace / "invoice.py").write_bytes(correct)
            (workspace / "tests/test_invoice.py").write_text("# weakened tests\n")
            self.assertFalse(grade(workspace, {"events": [event]}, FIXTURE)["hard_gates"]["scope_preserved"])

    def test_actual_payload_ablation_audit(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            def save(name, value): (p / name).write_text(json.dumps(value))
            state = '<operational-state>{"name":"write"}</operational-state>'
            seed = {"arm": "with_state", "scenario": "stale_pass", "compacted": True,
                    "summary": "same summary", "checkpoint": state,
                    "events": [{"phase": "finish", "name": n, "result": {"is_error": False}} for n in ("run", "write")]}
            report = {"operational_screen": {k: seed[k] for k in ("arm", "scenario", "compacted")}}
            request = {"messages": [{"text": "same summary"}, {"text": state}]}
            payload = {"input": [{"content": [{"type": "input_text", "text": state}]}]}
            save("operational-screen.json", seed); save("request-0001.json", request); save("provider-request-0001.json", payload)
            audit(p, "with_state", [p / "request-0001.json"], report)
            save("provider-request-0001.json", {"input": []})
            with self.assertRaisesRegex(ValueError, "missing operational"): audit(p, "with_state", [p / "request-0001.json"], report)
            seed["arm"] = "without_state"; report["operational_screen"]["arm"] = "without_state"
            save("operational-screen.json", seed)
            with self.assertRaisesRegex(ValueError, "control leaked"): audit(p, "without_state", [p / "request-0001.json"], report)
            request["messages"].pop(); save("request-0001.json", request)
            audit(p, "without_state", [p / "request-0001.json"], report)


if __name__ == "__main__": unittest.main()
