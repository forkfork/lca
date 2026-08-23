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
        [sys.executable, "-c", source], cwd=workspace, text=True,
        capture_output=True, timeout=30,
    )
    return completed.returncode == 0, (completed.stdout + completed.stderr)[-4000:]


public = subprocess.run(
    [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
    cwd=workspace, text=True, capture_output=True, timeout=30,
)
hidden_ok, hidden_output = run_python(r'''from checkout import Customer, LineItem, QuoteService

cart = [LineItem("same", 1250, 2)]

regular_then_vip = QuoteService()
assert regular_then_vip.quote(Customer("regular-a"), cart) == 2500
assert regular_then_vip.quote(Customer("vip-a", "vip"), cart) == 2000

vip_then_regular = QuoteService()
assert vip_then_regular.quote(Customer("vip-b", "vip"), cart) == 2000
assert vip_then_regular.quote(Customer("regular-b"), cart) == 2500

tier_changes = QuoteService()
customer = Customer("changing")
assert tier_changes.quote(customer, cart) == 2500
customer.tier = "vip"
assert tier_changes.quote(customer, cart) == 2000

shared_pricing = QuoteService()
assert shared_pricing.quote(Customer("one", "vip"), cart) == 2000
size_after_first = len(shared_pricing.cache)
assert shared_pricing.quote(Customer("two", "vip"), cart) == 2000
assert len(shared_pricing.cache) == size_after_first, "equivalent VIP inputs should reuse cache"

different_quantity = [LineItem("same", 1250, 3)]
assert shared_pricing.quote(Customer("three", "vip"), different_quantity) == 3000
''')

ignored = {"__pycache__", ".pytest_cache"}
fixture_files = {
    path.relative_to(fixture).as_posix(): path.read_bytes()
    for path in fixture.rglob("*") if path.is_file() and not ignored.intersection(path.parts)
}
workspace_files = {
    path.relative_to(workspace).as_posix(): path.read_bytes()
    for path in workspace.rglob("*") if path.is_file() and not ignored.intersection(path.parts)
}
changed = sorted(name for name, body in fixture_files.items() if workspace_files.get(name) != body)
added = sorted(name for name in workspace_files if name not in fixture_files)
allowed = {"checkout/cache.py", "checkout/service.py"}
scope_ok = bool(changed) and set(changed).issubset(allowed) and not added

changed_lines = 0
for name in changed:
    before = fixture_files[name].decode("utf-8", "replace").splitlines()
    after = workspace_files[name].decode("utf-8", "replace").splitlines()
    changed_lines += sum(line.startswith(("- ", "+ ")) for line in difflib.ndiff(before, after))

events = trajectory.get("events", [])
completed = [(index, event) for index, event in enumerate(events) if event.get("result")]
successful_mutations = [
    (index, event) for index, event in completed
    if event.get("name") in ("edit", "write", "file_change", "mutation")
    and not event["result"].get("is_error")
]
first_mutation = successful_mutations[0][0] if successful_mutations else None
reproductions = [
    (index, event) for index, event in completed
    if event.get("name") in ("run", "shell", "command_execution") and event["result"].get("is_error")
    and "test_vip_quote_after_regular_same_cart" in event["result"].get("content", "")
]
reproduced_before_edit = bool(
    reproductions and first_mutation is not None and reproductions[0][0] < first_mutation
)
green_after_edit = any(
    index > first_mutation
    and event.get("name") in ("run", "shell", "command_execution")
    and not event["result"].get("is_error")
    and (
        "unittest" in str(event.get("args", {}).get("command", "")).lower()
        or "pytest" in str(event.get("args", {}).get("command", "")).lower()
    )
    for index, event in completed
) if first_mutation is not None else False
relevant_reads = {
    event.get("args", {}).get("path") for _, event in completed
    if event.get("name") == "read" and event.get("args", {}).get("path", "").startswith("checkout/")
}
reads_before_mutation = {
    event.get("args", {}).get("path") for index, event in completed
    if first_mutation is not None and index < first_mutation and event.get("name") == "read"
}
for index, event in completed:
    if first_mutation is None or index >= first_mutation:
        continue
    content = str(event.get("result", {}).get("content", ""))
    if "class QuoteService" in content and "def quote" in content:
        reads_before_mutation.add("checkout/service.py")
    if "class QuoteCache" in content and "def key" in content:
        reads_before_mutation.add("checkout/cache.py")
    if "def discount_percent" in content:
        reads_before_mutation.add("checkout/discounts.py")
    if "class Customer" in content and "class LineItem" in content:
        reads_before_mutation.add("checkout/models.py")
required_trace = {"checkout/service.py", "checkout/cache.py", "checkout/discounts.py"}
traced_pricing_path = required_trace.issubset(reads_before_mutation)

hard_gates = {
    "reproduced_report_before_edit": reproduced_before_edit,
    "traced_pricing_path_before_edit": traced_pricing_path,
    "public_tests": public.returncode == 0,
    "hidden_cross_customer_and_cache_behavior": hidden_ok,
    "successful_verification_after_edit": green_after_edit,
    "scope_control": scope_ok,
}
dimensions = {
    "investigation": 20 if reproduced_before_edit else 0,
    "behavior": 50 if public.returncode == 0 and hidden_ok else 0,
    "verification": 15 if green_after_edit else 0,
    "scope": 10 if scope_ok else 0,
    "communication": 5 if trajectory.get("final", "").strip() else 0,
}

print(json.dumps({
    "score": sum(dimensions.values()),
    "passed": all(hard_gates.values()),
    "dimensions": dimensions,
    "hard_gates": hard_gates,
    "evidence": {
        "changed_files": changed,
        "added_files": added,
        "changed_lines": changed_lines,
        "verification_runs": sum(
            event.get("name") in ("run", "shell", "command_execution") for _, event in completed
        ),
        "failed_verification_runs": sum(
            event.get("name") in ("run", "shell", "command_execution")
            and event["result"].get("is_error") for _, event in completed
        ),
        "reproduced_before_edit": reproduced_before_edit,
        "traced_pricing_path_before_edit": traced_pricing_path,
        "source_reads_before_edit": sorted(path for path in reads_before_mutation if path),
        "relevant_source_reads": sorted(path for path in relevant_reads if path),
        "relevant_source_reads_count": len(relevant_reads),
        "public_test_output": (public.stdout + public.stderr)[-4000:],
        "hidden_test_output": hidden_output,
    },
}))
