import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCENARIO = Path(__file__).resolve().parents[1] / "scenarios/context_boundary_edit"


class ContextBoundaryGraderTests(unittest.TestCase):
    def grade(self, extra_file=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scenario = root / "scenario"
            shutil.copytree(SCENARIO, scenario)
            cache = scenario / "fixture/pipelines/__pycache__"
            cache.mkdir(exist_ok=True)
            (cache / "irrelevant.pyc").write_bytes(b"fixture cache noise")
            workspace = root / "workspace"
            shutil.copytree(scenario / "fixture", workspace)
            source = workspace / "pipelines/rules.py"
            prefix, export = source.read_text().split('    "export": Pipeline(', 1)
            source.write_text(prefix + '    "export": Pipeline(' + export.replace("timeout_seconds=60, retries=2", "timeout_seconds=90, retries=4", 1))
            if extra_file:
                (workspace / "unrequested.txt").write_text("scope violation")
            trajectory = root / "trajectory.json"
            trajectory.write_text(json.dumps({"events": [{"phase": "finish", "name": "run",
                "args": {"command": "python3 -m unittest discover -s tests -v"},
                "result": {"is_error": False, "content": "Ran 3 tests\nOK\n"}}]}))
            result = subprocess.run([sys.executable, str(scenario / "grade.py"), str(workspace), str(trajectory)],
                                    check=True, capture_output=True, text=True,
                                    env={**os.environ, "PYTHONPATH": str(SCENARIO.parents[1])})
            return json.loads(result.stdout)

    def test_correct_patch_passes_even_with_fixture_bytecode(self):
        result = self.grade()
        self.assertTrue(result["passed"], result)
        self.assertEqual(result["evidence"]["changed_files"], ["pipelines/rules.py"])

    def test_real_extra_file_still_fails_scope(self):
        self.assertFalse(self.grade(extra_file=True)["hard_gates"]["scope_control"])


if __name__ == "__main__":
    unittest.main()
