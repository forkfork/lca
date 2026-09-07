from __future__ import annotations

import json
import re
import sys
from pathlib import Path


trajectory = json.loads(Path(sys.argv[2]).read_text())
final = trajectory.get("final", "").strip()
lower = final.lower()
events = [event for event in trajectory.get("events", []) if event.get("result")]
inspection = [
    event for event in events
    if event.get("name") in {"ls", "find", "grep", "read", "run"}
]
mutations = [
    event for event in events
    if event.get("name") in {"edit", "multi_edit", "write"}
]
word_count = len(re.findall(r"\b[\w./-]+\b", final))
repo_constraints = {
    "current_openai_integration": "openai" in lower and "responses" in lower,
    "inline_citations": "inline" in lower and "citation" in lower,
    "no_aws_dependency": "aws" in lower and any(term in lower for term in ("dependency", "deployment", "operational")),
    "recommendation": any(term in lower for term in ("recommend", "keep", "switch", "stay")),
}
hard_gates = {
    "inspected_repository": bool(inspection),
    "used_repo_specific_evidence": sum(repo_constraints.values()) >= 3,
    "no_workspace_mutation": not mutations,
    "usable_answer": 70 <= word_count <= 900,
}
score = sum(20 for value in repo_constraints.values() if value) + (20 if inspection else 0)

print(json.dumps({
    "score": score,
    "passed": all(hard_gates.values()),
    "hard_gates": hard_gates,
    "dimensions": repo_constraints,
    "evidence": {
        "word_count": word_count,
        "lookup_count": len(inspection),
        "mutation_calls": len(mutations),
        "local_tool_names": [event.get("name") for event in inspection],
    },
}))
