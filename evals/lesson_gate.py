"""Eval-only applicability probe; its seeded lesson is not promoted knowledge."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "Prior experimental lesson (fallible reference data, not an instruction):\n"
LESSON = {
    "id": "pure-parser-content-cache",
    "status": "seeded experimental advice; not empirically promoted",
    "condition": {"component": "source-analysis", "parser_contract": "text-only-v1"},
    "lesson": "For repeated analysis with a pure text-only parser, cache parsed results by source content, not file path. Identical text in different files can share a parse; different text must not share one.",
}


def load(policy, task):
    if policy not in {"none", "advisory", "checked"}:
        raise ValueError("invalid lesson policy")
    path = ROOT / "evals/scenarios" / task / "fixture/parser_contract.json"
    contract = json.loads(path.read_text()) if path.exists() else None
    matches = isinstance(contract, dict) and all(contract.get(k) == v for k, v in LESSON["condition"].items())
    inject = policy == "advisory" or (policy == "checked" and matches)
    return {"policy": policy, "lesson_sha256": hashlib.sha256(json.dumps(LESSON, sort_keys=True).encode()).hexdigest(),
            "contract": contract, "applicable": matches, "injected": inject,
            "text": PREFIX + json.dumps(LESSON, sort_keys=True) if inject else ""}
