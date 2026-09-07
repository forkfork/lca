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
    [sys.executable, "-c", "from diagnostics import format_status; assert format_status('timeout',' x ') == 'request_timeout:x'; assert format_status('unavailable','x') == 'service_unavailable:x'; assert format_status('mystery','x') == 'request_unknown:x'"],
    cwd=workspace, text=True, capture_output=True, timeout=30,
)

def files(root: Path) -> dict[str, bytes]:
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file() and "__pycache__" not in p.parts}

before, after = files(fixture), files(workspace)
changed = sorted(path for path, body in before.items() if after.get(path) != body)
added = sorted(path for path in after if path not in before)
scope_ok = changed == ["diagnostics/formatter.py"] and not added
changed_lines = sum(
    line.startswith(("- ", "+ "))
    for name in changed
    for line in difflib.ndiff(before[name].decode().splitlines(), after[name].decode().splitlines())
)
events = [event for event in trajectory.get("events", []) if event.get("result")]
grep_indexes = [i for i, event in enumerate(events) if event.get("name") == "grep"]
first_grep = min(grep_indexes, default=len(events))
source_reads_after_grep = sum(
    event.get("name") == "read" and str(event.get("args", {}).get("path", "")).endswith("diagnostics/formatter.py")
    for event in events[first_grep + 1:]
)
verification_runs = sum(event.get("name") == "run" and "test" in str(event.get("args", {}).get("command", "")).lower() for event in events)
checks = {"public_tests": public.returncode == 0, "hidden_behavior": hidden.returncode == 0, "scope": scope_ok, "used_grep": bool(grep_indexes), "verified": verification_runs > 0}
dimensions = {"behavior": 70 if checks["public_tests"] and checks["hidden_behavior"] else 0, "scope": 15 if scope_ok else 0, "verification": 10 if checks["verified"] else 0, "communication": 5 if trajectory.get("final", "").strip() else 0}
print(json.dumps({
    "score": sum(dimensions.values()), "passed": all(checks.values()), "dimensions": dimensions, "hard_gates": checks,
    "evidence": {"changed_files": changed, "added_files": added, "changed_lines": changed_lines, "lookup_count": len(grep_indexes), "relevant_source_reads_count": source_reads_after_grep, "verification_runs": verification_runs, "public_test_output": (public.stdout + public.stderr)[-2000:]},
}))
