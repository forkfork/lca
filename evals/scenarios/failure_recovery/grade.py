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
    [sys.executable, "-c", '''from shipping import quote
assert quote(0) == 0
assert quote(0, True) == 0
assert quote(0, fragile=True) == 0
assert quote(1) == 620
assert quote(1001) == 740
assert quote(1, True) == 1320
assert quote(1, fragile=True) == 870
assert quote(1, expedited=True, fragile=True) == 1570
try:
    quote(-1)
except ValueError as exc:
    assert "negative" in str(exc)
else:
    raise AssertionError("negative weight accepted")
'''],
    cwd=workspace, text=True, capture_output=True, timeout=30,
)

fixture_files = {
    p.relative_to(fixture).as_posix(): p.read_bytes() for p in fixture.rglob("*")
    if p.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(p.parts)
}
workspace_files = {
    p.relative_to(workspace).as_posix(): p.read_bytes() for p in workspace.rglob("*")
    if p.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(p.parts)
}
changed = sorted(name for name, body in fixture_files.items() if workspace_files.get(name) != body)
added = sorted(name for name in workspace_files if name not in fixture_files)
scope_ok = changed == ["shipping/quotes.py"] and not added

before = fixture_files["shipping/quotes.py"].decode().splitlines()
after = workspace_files.get("shipping/quotes.py", b"").decode("utf-8", "replace").splitlines()
changed_lines = sum(line.startswith(("- ", "+ ")) for line in difflib.ndiff(before, after))

events = trajectory.get("events", [])
completed = [(index, event) for index, event in enumerate(events) if event.get("result")]
failed_runs = [
    (index, event) for index, event in completed
    if event.get("name") in ("run", "shell", "command_execution") and event["result"].get("is_error")
]
injected_failures = [
    (index, event) for index, event in failed_runs
    if "test_zero_weight_is_free" in event["result"].get("content", "")
    or "500 != 0" in event["result"].get("content", "")
]
failure_index = injected_failures[0][0] if injected_failures else None
successful_runs_after = [
    event for index, event in completed
    if failure_index is not None and index > failure_index and event.get("name") in ("run", "shell", "command_execution")
    and not event["result"].get("is_error")
]
recovery_mutations = [
    event for index, event in completed
    if failure_index is not None and index > failure_index and event.get("name") in ("edit", "write", "file_change", "mutation")
    and not event["result"].get("is_error")
]

hard_gates = {
    "mutation_injected": bool(trajectory.get("recovery_mutation_applied")),
    "injected_failure_observed": bool(injected_failures),
    "recovery_mutation_performed": bool(recovery_mutations),
    "recovered_to_green": bool(successful_runs_after),
    "target_and_compatibility_behavior": behavior.returncode == 0,
    "scope_control": scope_ok,
}

print(json.dumps({
    "score": sum((10, 15, 15, 20, 30, 10)[index] for index, passed in enumerate(hard_gates.values()) if passed),
    "passed": all(hard_gates.values()),
    "hard_gates": hard_gates,
    "evidence": {
        "changed_files": changed,
        "added_files": added,
        "changed_lines": changed_lines,
        "verification_runs": sum(event.get("name") in ("run", "shell", "command_execution") for _, event in completed),
        "failed_verification_runs": len(failed_runs),
        "successful_verification_runs_after_failure": len(successful_runs_after),
        "recovery_mutations_after_failure": len(recovery_mutations),
        "behavior_output": (behavior.stdout + behavior.stderr)[-4000:],
    },
}))
