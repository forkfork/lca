from __future__ import annotations

import difflib
import json
import subprocess
import sys
from pathlib import Path


workspace = Path(sys.argv[1])
trajectory = json.loads(Path(sys.argv[2]).read_text())
fixture = Path(__file__).with_name("fixture")


def run_python(source: str) -> tuple[bool, str]:
    completed = subprocess.run(
        [sys.executable, "-c", source],
        cwd=workspace,
        text=True,
        capture_output=True,
        timeout=30,
    )
    detail = (completed.stdout + completed.stderr)[-4000:]
    return completed.returncode == 0, detail


public = subprocess.run(
    [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
    cwd=workspace,
    text=True,
    capture_output=True,
    timeout=30,
)

hidden_source = r'''from decimal import Decimal
from checkout import DiscountRule, LineItem, parse_discount_rule, quote

missing = parse_discount_rule({"code": "OPEN", "percent": "12.5"})
assert missing.maximum_discount_cents is None
assert parse_discount_rule({"code": "NULL", "percent": 10, "maximum_discount_cents": None}).maximum_discount_cents is None

capped = parse_discount_rule({"code": "CAP", "percent": "12.5", "maximum_discount_cents": 100})
assert capped.maximum_discount_cents == 100
result = quote([LineItem("item", 999)], capped, Decimal("10"))
assert result.discount_cents == 100, result
assert result.tax_cents == 90, result
assert result.total_cents == 989, result

zero = DiscountRule("ZERO", Decimal("99"), maximum_discount_cents=0)
result = quote([LineItem("item", 999)], zero)
assert result.discount_cents == 0 and result.total_cents == 999

uncapped = DiscountRule("OLD", Decimal("12.5"))
assert quote([LineItem("item", 999)], uncapped).discount_cents == 125

for bad in (-1, True, False, 1.5, "10"):
    try:
        DiscountRule("BAD", Decimal("10"), maximum_discount_cents=bad)
    except ValueError:
        pass
    else:
        raise AssertionError(f"direct model accepted invalid cap: {bad!r}")
    try:
        parse_discount_rule({"code": "BAD", "percent": 10, "maximum_discount_cents": bad})
    except ValueError:
        pass
    else:
        raise AssertionError(f"parser accepted invalid cap: {bad!r}")
'''
hidden_ok, hidden_detail = run_python(hidden_source)

fixture_files = {
    path.relative_to(fixture).as_posix(): path.read_bytes()
    for path in fixture.rglob("*")
    if path.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(path.parts)
}
workspace_files = {
    path.relative_to(workspace).as_posix(): path.read_bytes()
    for path in workspace.rglob("*")
    if path.is_file() and "__pycache__" not in path.parts
}
changed = sorted(
    path for path, original in fixture_files.items()
    if workspace_files.get(path) != original
)
added = sorted(path for path in workspace_files if path not in fixture_files)
allowed_changes = {"checkout/models.py", "checkout/config.py", "checkout/pricing.py"}
scope_ok = set(changed).issubset(allowed_changes) and not added
required_files_changed = {
    name: name in changed
    for name in ("checkout/models.py", "checkout/config.py", "checkout/pricing.py")
}

changed_lines = 0
for name in changed:
    before = fixture_files[name].decode("utf-8", "replace").splitlines()
    after = workspace_files[name].decode("utf-8", "replace").splitlines()
    for line in difflib.ndiff(before, after):
        if line.startswith("- ") or line.startswith("+ "):
            changed_lines += 1

action_events = [event for event in trajectory.get("events", []) if event.get("result")]
mutation_starts = [
    event for event in action_events
    if event.get("name") in ("edit", "write", "file_change", "mutation")
]
failed_mutations = [
    event for event in trajectory.get("events", [])
    if event.get("name") in ("edit", "write")
    and event.get("result", {}).get("is_error")
]
existing_paths = set(fixture_files)
existing_file_writes = [
    event.get("args", {}).get("path") for event in mutation_starts
    if event.get("name") == "write" and event.get("args", {}).get("path") in existing_paths
]
verification_runs = [
    event for event in action_events
    if event.get("name") in ("run", "shell", "command_execution")
    and any(term in str(event.get("args", {}).get("command", "")).lower() for term in ("test", "pytest", "unittest"))
]

checks = {
    "public_tests": public.returncode == 0,
    "hidden_behavior": hidden_ok,
    "scope_control": scope_ok,
    "all_required_files_changed": all(required_files_changed.values()),
}
hard_gates = dict(checks)
dimensions = {
    "behavior": 75 if checks["public_tests"] and checks["hidden_behavior"] else 0,
    "scope": 15 if checks["scope_control"] and checks["all_required_files_changed"] else 0,
    "verification": 5 if verification_runs else 0,
    "communication": 5 if trajectory.get("final", "").strip() else 0,
}

print(json.dumps({
    "score": sum(dimensions.values()),
    "passed": all(hard_gates.values()),
    "dimensions": dimensions,
    "hard_gates": hard_gates,
    "evidence": {
        "checks": checks,
        "required_files_changed": required_files_changed,
        "changed_files": changed,
        "added_files": added,
        "changed_lines": changed_lines,
        "edit_calls": sum(event.get("name") == "edit" for event in mutation_starts),
        "write_calls": sum(event.get("name") == "write" for event in mutation_starts),
        "mutation_calls": len(mutation_starts),
        "existing_file_writes": existing_file_writes,
        "existing_file_writes_count": len(existing_file_writes),
        "failed_mutations": len(failed_mutations),
        "verification_runs": len(verification_runs),
        "public_test_output": (public.stdout + public.stderr)[-4000:],
        "hidden_test_output": hidden_detail,
    },
}))
