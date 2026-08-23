from __future__ import annotations

import json
import sys
from pathlib import Path


workspace = Path(sys.argv[1])
trajectory = json.loads(Path(sys.argv[2]).read_text())
expected = {f"item{index:02}.txt": f"item {index:02}\n" for index in range(1, 16)}

checks = {
    name: (workspace / name).is_file() and (workspace / name).read_text() == content
    for name, content in expected.items()
}
actual_files = sorted(
    path.name for path in workspace.iterdir()
    if path.is_file() and path.name != "README.md"
)
checks["no_extra_files"] = actual_files == sorted(expected)
checks["readme_unchanged"] = (workspace / "README.md").read_text() == Path(__file__).with_name("fixture").joinpath("README.md").read_text()

start_events = [event for event in trajectory.get("events", []) if event.get("result")]
tool_names = [event.get("name") for event in start_events]
dimensions = {
    "file_correctness": round(85 * sum(checks[name] for name in expected) / len(expected)),
    "scope_control": 10 if checks["no_extra_files"] and checks["readme_unchanged"] else 0,
    "communication": 5 if trajectory.get("final", "").strip() else 0,
}
hard_gates = {
    "all_files_exact": all(checks[name] for name in expected),
    "no_scope_creep": checks["no_extra_files"] and checks["readme_unchanged"],
}

print(json.dumps({
    "score": sum(dimensions.values()),
    "passed": all(hard_gates.values()),
    "dimensions": dimensions,
    "hard_gates": hard_gates,
    "evidence": {
        "checks": checks,
        "actual_files": actual_files,
        "tool_count": len(start_events),
        "tool_names": tool_names,
    },
}))
