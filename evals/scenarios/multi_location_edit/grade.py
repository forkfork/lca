from __future__ import annotations

import difflib
import json
import subprocess
import sys
from pathlib import Path


workspace = Path(sys.argv[1])
trajectory = json.loads(Path(sys.argv[2]).read_text())
fixture = Path(__file__).with_name("fixture")

public = subprocess.run(
    [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
    cwd=workspace, text=True, capture_output=True, timeout=30,
)
hidden = subprocess.run(
    [sys.executable, "-c", '''from runtime.policy import *
assert request_timeout() == 45
for value in (" us-east ", "US-east", " us-WEST "):
    assert normalize_region(value) == value.strip().upper()
assert canonical_region(" eu ") == "EU-WEST-1"
assert endpoint_url(" example.test ") == "https://example.test:443"
assert endpoint_url("example.test", 8443) == "https://example.test:8443"
assert retry_delays("connect") == (1, 2, 4)
assert feature_enabled("regional_failover") is True
assert request_headers() == {"accept": "application/json", "user-agent": "lca-runtime/1", "x-client-mode": "bounded"}
assert service_port("health") == 8080
'''],
    cwd=workspace, text=True, capture_output=True, timeout=30,
)

def source_files(root: Path) -> dict[str, bytes]:
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(path.parts)
    }


fixture_files = source_files(fixture)
workspace_files = source_files(workspace)
changed = sorted(name for name, body in fixture_files.items() if workspace_files.get(name) != body)
added = sorted(name for name in workspace_files if name not in fixture_files)
scope_ok = changed == ["runtime/policy.py"] and not added

before = fixture_files["runtime/policy.py"].decode().splitlines()
after = workspace_files.get("runtime/policy.py", b"").decode("utf-8", "replace").splitlines()
changed_lines = sum(line.startswith(("- ", "+ ")) for line in difflib.ndiff(before, after))

events = trajectory.get("events", [])
completed = [event for event in events if event.get("result")]
mutations = [
    event for event in completed
    if event.get("name") in ("edit", "multi_edit", "write", "file_change", "mutation")
]
failed = [event for event in mutations if event.get("result", {}).get("is_error")]
verification = [
    event for event in completed
    if event.get("name") in ("run", "shell", "command_execution")
    and any(term in str(event.get("args", {}).get("command", "")).lower() for term in ("test", "pytest", "unittest"))
    and not event.get("result", {}).get("is_error")
]
existing_writes = [
    event for event in mutations
    if event.get("name") == "write" and event.get("args", {}).get("path") in fixture_files
]

max_hunk_span = 0
for event in mutations:
    args = event.get("args", {})
    hunks = args.get("edits") if event.get("name") == "multi_edit" else [args]
    if not isinstance(hunks, list):
        continue
    for hunk in hunks:
        if isinstance(hunk, dict) and hunk.get("start_line") is not None:
            start = int(hunk["start_line"])
            end = int(hunk.get("end_line", start))
            max_hunk_span = max(max_hunk_span, end - start + 1)

surgical_edits = not existing_writes and max_hunk_span <= 10
hard_gates = {
    "public_tests": public.returncode == 0,
    "hidden_behavior": hidden.returncode == 0,
    "scope_control": scope_ok,
    "surgical_edits": surgical_edits,
    "successful_verification": bool(verification),
}
print(json.dumps({
    "score": (65 if hard_gates["public_tests"] and hard_gates["hidden_behavior"] else 0)
        + (15 if scope_ok else 0) + (10 if surgical_edits else 0)
        + (5 if verification else 0) + (5 if trajectory.get("final", "").strip() else 0),
    "passed": all(hard_gates.values()),
    "hard_gates": hard_gates,
    "evidence": {
        "changed_files": changed,
        "added_files": added,
        "changed_lines": changed_lines,
        "edit_calls": sum(event.get("name") == "edit" for event in mutations),
        "multi_edit_calls": sum(event.get("name") == "multi_edit" for event in mutations),
        "write_calls": sum(event.get("name") == "write" for event in mutations),
        "mutation_calls": len(mutations),
        "failed_mutations": len(failed),
        "existing_file_writes_count": len(existing_writes),
        "verification_runs": len(verification),
        "max_hunk_span": max_hunk_span,
        "public_test_output": (public.stdout + public.stderr)[-4000:],
        "hidden_test_output": (hidden.stdout + hidden.stderr)[-4000:],
    },
}))
