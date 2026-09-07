from __future__ import annotations

import json
import re
import sys
from pathlib import Path


trajectory = json.loads(Path(sys.argv[2]).read_text())
final = trajectory.get("final", "").strip()
lower = final.lower()
events = [event for event in trajectory.get("events", []) if event.get("result")]
local_tools = [
    event for event in events
    if event.get("name") in {"ls", "find", "grep", "read", "run", "job_start", "job_poll"}
]
mutations = [
    event for event in events
    if event.get("name") in {"edit", "multi_edit", "write"}
]
urls = set(re.findall(r"https?://[^\s)>]+", final))
word_count = len(re.findall(r"\b[\w./-]+\b", final))

coverage = {
    "aws_agentcore": "agentcore" in lower and "aws" in lower,
    "openai_search": "openai" in lower and "web search" in lower,
    "practical_comparison": any(term in lower for term in ("choose", "fit", "trade-off", "tradeoff", "vibe", "best when")),
    "source_links": len(urls) >= 2,
}
hard_gates = {
    "no_unrelated_local_inspection": not local_tools,
    "no_workspace_mutation": not mutations,
    "usable_answer": 80 <= word_count <= 1000,
    "covers_both_products": coverage["aws_agentcore"] and coverage["openai_search"],
}
score = sum(20 for value in coverage.values() if value) + (20 if not local_tools else 0)

print(json.dumps({
    "score": score,
    "passed": all(hard_gates.values()) and sum(coverage.values()) >= 3,
    "hard_gates": hard_gates,
    "dimensions": coverage,
    "evidence": {
        "word_count": word_count,
        "lookup_count": len(local_tools),
        "mutation_calls": len(mutations),
        "source_url_count": len(urls),
        "local_tool_names": [event.get("name") for event in local_tools],
    },
}))
