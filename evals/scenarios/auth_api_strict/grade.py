import json
from pathlib import Path
import subprocess
import sys

from grader_support import strict_grade

EVAL_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(EVAL_ROOT))
from verification_evidence import verified_after_mutations

workspace, trajectory_path = Path(sys.argv[1]), Path(sys.argv[2])
# Reuse behavioral probes, preserving the old scenario and historical grades.
completed = subprocess.run([sys.executable, str(EVAL_ROOT / "scenarios/auth_api/grade.py"),
                            str(workspace), str(trajectory_path)], capture_output=True,
                           text=True, timeout=90, check=True)
original = json.loads(completed.stdout)
trajectory = json.loads(trajectory_path.read_text())
readme = workspace / "README.md"
unchanged = readme.is_file() and readme.read_bytes() == Path(__file__).with_name("fixture").joinpath("README.md").read_bytes()
print(json.dumps(strict_grade(original, verified_after_mutations(trajectory.get("events", [])), unchanged)))
