from __future__ import annotations

import difflib
import json
import subprocess
import sys
from pathlib import Path

from grader_support import successful_test_evidence


workspace = Path(sys.argv[1])
trajectory = json.loads(Path(sys.argv[2]).read_text())
fixture = Path(__file__).with_name("fixture")


def run_python(source: str) -> tuple[bool, str]:
    completed = subprocess.run(
        [sys.executable, "-c", source], cwd=workspace, text=True,
        capture_output=True, timeout=30,
    )
    return completed.returncode == 0, (completed.stdout + completed.stderr)[-6000:]


public = subprocess.run(
    [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
    cwd=workspace, text=True, capture_output=True, timeout=30,
)
hidden_ok, hidden_output = run_python(r'''import json
from orders import (
    ConflictError, NotFoundError, Order, OrderAPI, OrderRepository, OrderService,
    OrderStatus,
)

repo = OrderRepository([
    Order("a", "customer", 1000),
    Order("b", "customer", 2000),
    Order("shipped", "customer", 3000, OrderStatus.SHIPPED),
])
service = OrderService(repo)
api = OrderAPI(service)

# Direct service behavior and normalized idempotency.
cancelled = service.cancel_order("a", "  request-1  ")
assert cancelled.status.value == "cancelled"
events = repo.events_for("a")
assert len(events) == 1 and events[0].kind == "cancelled"
assert events[0].request_id == "request-1"
assert service.cancel_order("a", "request-1") == cancelled
assert len(repo.events_for("a")) == 1

# The same request ID belongs to an order, not a global namespace.
assert service.cancel_order("b", "request-1").status.value == "cancelled"
assert len(repo.events_for("b")) == 1

try:
    service.cancel_order("a", "another-request")
except ConflictError:
    pass
else:
    raise AssertionError("different retry cancelled an already-cancelled order")

try:
    service.cancel_order("shipped", "ship-cancel")
except ConflictError:
    pass
else:
    raise AssertionError("shipped order was cancelled")
assert repo.events_for("shipped") == []

try:
    service.cancel_order("missing", "missing-cancel")
except NotFoundError:
    pass
else:
    raise AssertionError("missing order did not raise NotFoundError")

# Invalid IDs are rejected before mutation.
before = list(repo.events_for("shipped"))
for bad in (None, "", "   ", 42, "x" * 65):
    try:
        service.cancel_order("shipped", bad)
    except ValueError:
        pass
    else:
        raise AssertionError(f"accepted invalid request ID: {bad!r}")
assert repo.events_for("shipped") == before

# API status/error mapping and exact existing response shape.
fresh_repo = OrderRepository([
    Order("api", "customer", 400),
    Order("api-shipped", "customer", 500, OrderStatus.SHIPPED),
])
fresh_api = OrderAPI(OrderService(fresh_repo))
response = fresh_api.handle("POST", "/orders/api/cancel", json.dumps({"request_id": "api-1"}))
assert response.status == 200 and response.body == {
    "order_id": "api", "customer_id": "customer", "total_cents": 400,
    "status": "cancelled",
}
assert fresh_api.handle("POST", "/orders/api/cancel", '{bad json').status == 400
assert fresh_api.handle("POST", "/orders/api/cancel", '{}').status == 400
assert fresh_api.handle("POST", "/orders/missing/cancel", '{"request_id":"x"}').status == 404
conflict = fresh_api.handle(
    "POST", "/orders/api-shipped/cancel", '{"request_id":"x"}'
)
assert conflict.status == 409 and conflict.body["error"] == "conflict"

# Existing shipping and queries remain usable after the feature addition.
legacy_repo = OrderRepository([Order("legacy", "legacy-customer", 900)])
legacy_service = OrderService(legacy_repo)
assert legacy_service.get_order("legacy").status is OrderStatus.PENDING
assert legacy_service.list_orders("legacy-customer")[0].order_id == "legacy"
assert legacy_service.ship_order("legacy").status is OrderStatus.SHIPPED
assert [event.kind for event in legacy_repo.events_for("legacy")] == ["shipped"]
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
allowed = {
    "orders/__init__.py", "orders/api.py", "orders/models.py",
    "orders/repository.py", "orders/service.py",
}
scope_ok = bool(changed) and set(changed).issubset(allowed) and not added
layering_ok = (
    "orders/service.py" in changed
    and "orders/api.py" in changed
    and bool({"orders/models.py", "orders/repository.py"}.intersection(changed))
)

changed_lines = 0
for name in changed:
    before = fixture_files[name].decode("utf-8", "replace").splitlines()
    after = workspace_files[name].decode("utf-8", "replace").splitlines()
    changed_lines += sum(line.startswith(("- ", "+ ")) for line in difflib.ndiff(before, after))

events = trajectory.get("events", [])
completed = [(index, event) for index, event in enumerate(events) if event.get("result")]
successful_mutations = [
    (index, event) for index, event in completed
    if event.get("name") in ("edit", "multi_edit", "write", "file_change", "mutation")
    and not event["result"].get("is_error")
]
first_mutation = successful_mutations[0][0] if successful_mutations else None
green_after_edit = any(
    index > first_mutation
    and event.get("name") in ("run", "shell", "command_execution")
    and successful_test_evidence(event)
    for index, event in completed
) if first_mutation is not None else False
reads_before_edit = {
    event.get("args", {}).get("path") for index, event in completed
    if first_mutation is not None and index < first_mutation and event.get("name") == "read"
}
for index, event in completed:
    if first_mutation is None or index >= first_mutation:
        continue
    content = str(event.get("result", {}).get("content", ""))
    for path, marker in (
        ("orders/models.py", "class OrderStatus"),
        ("orders/repository.py", "class OrderRepository"),
        ("orders/service.py", "class OrderService"),
        ("orders/api.py", "class OrderAPI"),
    ):
        if marker in content:
            reads_before_edit.add(path)
architecture_inspected = len({
    "orders/models.py", "orders/repository.py", "orders/service.py", "orders/api.py",
}.intersection(reads_before_edit)) >= 3

hard_gates = {
    "public_tests": public.returncode == 0,
    "hidden_idempotency_api_and_compatibility": hidden_ok,
    "scope_control": scope_ok,
    "coherent_layers_changed": layering_ok,
    "architecture_inspected_before_edit": architecture_inspected,
    "successful_verification_after_edit": green_after_edit,
}
dimensions = {
    "behavior": 55 if public.returncode == 0 and hidden_ok else 0,
    "architecture": 15 if layering_ok and architecture_inspected else 0,
    "scope": 10 if scope_ok else 0,
    "verification": 15 if green_after_edit else 0,
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
        "architecture_reads_before_edit": sorted(path for path in reads_before_edit if path),
        "relevant_source_reads_count": len(reads_before_edit),
        "mutation_calls": len(successful_mutations),
        "edit_calls": sum(event.get("name") == "edit" for _, event in successful_mutations),
        "multi_edit_calls": sum(event.get("name") == "multi_edit" for _, event in successful_mutations),
        "write_calls": sum(event.get("name") == "write" for _, event in successful_mutations),
        "failed_mutations": sum(
            event.get("name") in ("edit", "multi_edit", "write")
            and bool(event.get("result", {}).get("is_error"))
            for event in events
        ),
        "verification_runs": sum(
            event.get("name") in ("run", "shell", "command_execution")
            for _, event in completed
        ),
        "public_test_output": (public.stdout + public.stderr)[-6000:],
        "hidden_test_output": hidden_output,
    },
}))
