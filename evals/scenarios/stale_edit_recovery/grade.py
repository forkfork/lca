from __future__ import annotations

import difflib
import json
import subprocess
import sys
from pathlib import Path


workspace = Path(sys.argv[1])
trajectory = json.loads(Path(sys.argv[2]).read_text())
fixture = Path(__file__).with_name("fixture")
target = workspace / "runtime/settings.py"
body = target.read_text() if target.exists() else ""

behavior = subprocess.run(
    [sys.executable, "-c", '''from runtime import SETTINGS, timeout_for
assert timeout_for("request") == 45
assert timeout_for("connect") == 10
assert timeout_for("shutdown") == 15
'''],
    cwd=workspace, text=True, capture_output=True, timeout=30,
)
annotation_preserved = '"request_timeout_seconds": 45,  # managed by operations' in body

fixture_files = {
    p.relative_to(fixture).as_posix(): p.read_bytes() for p in fixture.rglob("*")
    if p.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(p.parts)
}
workspace_files = {
    p.relative_to(workspace).as_posix(): p.read_bytes() for p in workspace.rglob("*")
    if p.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(p.parts)
}
changed = sorted(name for name, original in fixture_files.items() if workspace_files.get(name) != original)
added = sorted(name for name in workspace_files if name not in fixture_files)
scope_ok = changed == ["runtime/settings.py"] and not added

before = fixture_files["runtime/settings.py"].decode().splitlines()
after = body.splitlines()
changed_lines = sum(line.startswith(("- ", "+ ")) for line in difflib.ndiff(before, after))
events = trajectory.get("events", [])
starts = [e for e in events if e.get("result")]
mutations = [e for e in starts if e.get("name") in ("edit", "multi_edit", "write", "file_change", "mutation")]
failed = [e for e in events if e.get("name") in ("edit", "multi_edit", "write") and e.get("result", {}).get("is_error")]
existing_writes = [e for e in mutations if e.get("name") == "write" and e.get("args", {}).get("path") in fixture_files]
verification = [
    e for e in starts if e.get("name") in ("run", "shell", "command_execution")
    and any(term in str(e.get("args", {}).get("command", "")).lower() for term in ("test", "pytest", "unittest"))
]

hard_gates = {
    "mutation_injected": bool(trajectory.get("stale_mutation_applied")),
    "target_behavior": behavior.returncode == 0,
    "concurrent_change_preserved": annotation_preserved,
    "scope_control": scope_ok,
}
print(json.dumps({
    "score": (65 if hard_gates["target_behavior"] else 0) + (20 if annotation_preserved else 0) + (10 if scope_ok else 0) + (5 if verification else 0),
    "passed": all(hard_gates.values()),
    "hard_gates": hard_gates,
    "evidence": {
        "changed_files": changed, "added_files": added, "changed_lines": changed_lines,
        "edit_calls": sum(e.get("name") == "edit" for e in mutations),
        "multi_edit_calls": sum(e.get("name") == "multi_edit" for e in mutations),
        "write_calls": sum(e.get("name") == "write" for e in mutations),
        "mutation_calls": len(mutations),
        "failed_mutations": len(failed), "existing_file_writes_count": len(existing_writes),
        "verification_runs": len(verification),
        "behavior_output": (behavior.stdout + behavior.stderr)[-4000:],
    },
}))
