import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCENARIO = Path(__file__).resolve().parents[1] / "scenarios/failure_recovery"


class FailureRecoveryGraderTests(unittest.TestCase):
    def test_correct_recovery_passes_but_wrong_artifact_or_missing_evidence_fails(self):
        for broken, evidence in ((False, True), (True, True), (False, False)):
            with self.subTest(broken=broken, evidence=evidence), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                workspace = root / "workspace"
                shutil.copytree(SCENARIO / "fixture", workspace)
                source = workspace / "shipping/quotes.py"
                source.write_text(source.read_text().replace(
                    "expedited: bool = False)", "expedited: bool = False, fragile: bool = False)"
                ).replace("    return total\n", "    return total + (250 if fragile else 0)\n"))
                if broken:
                    source.write_text(source.read_text().replace("ZERO_WEIGHT_CENTS = 0", "ZERO_WEIGHT_CENTS = 500"))
                events = [
                    {"name": "run", "result": {"is_error": True, "content": "FAIL test_zero_weight_is_free: 500 != 0"}},
                    {"name": "edit", "result": {"is_error": False, "content": "changed"}},
                    {"name": "run", "result": {"is_error": False, "content": "OK"}},
                ]
                trajectory = root / "trajectory.json"
                trajectory.write_text(json.dumps({"recovery_mutation_applied": True, "events": events if evidence else []}))
                completed = subprocess.run([sys.executable, str(SCENARIO / "grade.py"), str(workspace), str(trajectory)], text=True, capture_output=True, check=True)
                grade = json.loads(completed.stdout)
                self.assertEqual(grade["passed"], not broken and evidence, grade)


if __name__ == "__main__":
    unittest.main()
