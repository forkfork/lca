"""Regrade frozen pilot workspaces, preserving original results and protocol failures."""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def reviewed_result(original, trajectory, grade, grader_hash):
    result = dict(original)
    result["grading_review"] = {
        "original_passed": original.get("passed", False),
        "artifact_passed": grade["passed"],
        "grader_sha256": grader_hash,
    }
    if trajectory.get("ok"):
        for field in ("score", "passed", "hard_gates", "evidence", "dimensions"):
            if field in grade:
                result[field] = grade[field]
    else:
        result["passed"] = False  # Correct code cannot repair a failed state protocol.
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    count = 0
    for path in sorted((root / "results").glob("*/run-config.json")):
        config = json.loads(path.read_text())
        if config.get("theory") != "state_only_pilot" or config.get("order_seed") != args.seed:
            continue
        directory = path.parent
        original = json.loads((directory / "result.json").read_text())
        trajectory_path = directory / "trajectory.json"
        trajectory = json.loads(trajectory_path.read_text())
        grader = root / "scenarios" / config["scenario"]["id"] / "grade.py"
        completed = subprocess.run([sys.executable, str(grader), str(directory / "workspace"), str(trajectory_path)],
                                   capture_output=True, text=True, check=True, timeout=120)
        grade = json.loads(completed.stdout)
        result = reviewed_result(original, trajectory, grade, hashlib.sha256(grader.read_bytes()).hexdigest())
        (directory / "artifact-grade.json").write_text(json.dumps(grade, indent=2) + "\n")
        (directory / "result-reviewed.json").write_text(json.dumps(result, indent=2) + "\n")
        count += 1
    print(f"Regraded {count} frozen workspaces; original result.json files preserved.")


if __name__ == "__main__":
    main()
