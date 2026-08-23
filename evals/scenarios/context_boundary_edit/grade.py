from __future__ import annotations

import difflib
import json
import subprocess
import sys
from pathlib import Path


workspace = Path(sys.argv[1])
trajectory = json.loads(Path(sys.argv[2]).read_text())
fixture = Path(__file__).with_name("fixture")

behavior = subprocess.run(
    [sys.executable, "-c", '''from pipelines import PIPELINES
expected = {"ingest": (60, 2), "export": (90, 4), "archive": (60, 2)}
for name, values in expected.items():
    step = PIPELINES[name].steps[1]
    assert (step.timeout_seconds, step.retries) == values, (name, step)
'''],
    cwd=workspace, text=True, capture_output=True, timeout=30,
)

fixture_files = {p.relative_to(fixture).as_posix(): p.read_bytes() for p in fixture.rglob("*") if p.is_file()}
workspace_files = {
    p.relative_to(workspace).as_posix(): p.read_bytes() for p in workspace.rglob("*")
    if p.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(p.parts)
}
changed = sorted(name for name, body in fixture_files.items() if workspace_files.get(name) != body)
added = sorted(name for name in workspace_files if name not in fixture_files)
scope_ok = changed == ["pipelines/rules.py"] and not added

before = fixture_files["pipelines/rules.py"].decode().splitlines()
after = workspace_files.get("pipelines/rules.py", b"").decode("utf-8", "replace").splitlines()
changed_lines = sum(line.startswith(("- ", "+ ")) for line in difflib.ndiff(before, after))
events = trajectory.get("events", [])
starts = [event for event in events if event.get("phase") == "start"]
verification = [event for event in starts if event.get("name") == "run"]
hard_gates = {
    "latest_correction_retained": behavior.returncode == 0,
    "scope_control": scope_ok,
    "verification_performed": bool(verification),
}

print(json.dumps({
    "score": sum((80, 15, 5)[index] for index, passed in enumerate(hard_gates.values()) if passed),
    "passed": all(hard_gates.values()),
    "hard_gates": hard_gates,
    "evidence": {
        "changed_files": changed,
        "added_files": added,
        "changed_lines": changed_lines,
        "verification_runs": len(verification),
        "context_compaction_count": int(trajectory.get("context_compaction_count", 0)),
        "behavior_output": (behavior.stdout + behavior.stderr)[-4000:],
    },
}))
