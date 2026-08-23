from __future__ import annotations

import json
import re
import sys
from pathlib import Path


trajectory = json.loads(Path(sys.argv[2]).read_text())
answer = trajectory.get("final", "").strip()
tool_calls = int(trajectory.get("tool_calls", 0))
llm_calls = int(trajectory.get("llm_calls", 0))
answer_correct = bool(re.fullmatch(
    r"\s*(?:17\s*(?:\*|x|×|multiplied by)\s*23\s*=\s*)?391[.!]?\s*",
    answer,
    re.IGNORECASE,
))

dimensions = {
    "correctness": 70 if answer_correct else 0,
    "tool_restraint": 20 if tool_calls == 0 else 0,
    "conciseness": 10 if answer_correct and len(answer) <= 40 else 0,
}
hard_gates = {
    "correct_answer": answer_correct,
    "no_tools": tool_calls == 0,
    "single_model_call": llm_calls == 1,
}

print(json.dumps({
    "score": sum(dimensions.values()),
    "passed": all(hard_gates.values()),
    "dimensions": dimensions,
    "hard_gates": hard_gates,
    "evidence": {
        "answer": answer,
        "tool_calls": tool_calls,
        "llm_calls": llm_calls,
        "elapsed_ms": trajectory.get("elapsed_ms"),
    },
}))
