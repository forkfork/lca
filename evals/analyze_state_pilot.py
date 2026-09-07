"""Read-only request isolation audit and descriptive pilot results (no adoption test)."""
from __future__ import annotations

import argparse
import json
import re
import statistics
from collections import defaultdict
from pathlib import Path


def audit_state_only(directory: Path) -> list[str]:
    errors = []
    initial = json.loads((directory / "initial-context.json").read_text())
    instructions = [
        {"role": "user", "text": m.get("text")}
        for m in initial if m["role"] == "user" and not m.get("tool_name")
    ]
    for path in sorted(directory.glob("request-*.json")):
        number = int(path.stem.split("-")[1])
        messages = json.loads(path.read_text())["messages"]
        expected = list(instructions)
        if number > 1:
            response = json.loads((directory / f"response-{number - 1:04}.json").read_text())
            match = re.search(r"<agent_state>\s*(.*?)\s*</agent_state>", response.get("text", ""), re.S)
            if not match:
                errors.append(f"{path.name}: continued after missing state")
                continue
            expected.append({"role": "user", "text": "Current explicit state:\n" + match[1], "_explicit_state": True})
            evidence = messages[-1]
            archive_path = Path(evidence.get("text", "").removeprefix("Latest observation evidence: "))
            if not archive_path.name.startswith("observation-"):
                errors.append(f"{path.name}: missing observation reference")
                continue
            # Resolve the basename against this run so copied result directories work.
            fresh = json.loads((directory / archive_path.name).read_text())
            for message in fresh:
                if message["role"] == "assistant":
                    calls = [item for item in message.get("provider_items", []) if item["type"] == "function_call"]
                    if calls:
                        expected.append({"role": "assistant", "text": "", "provider_items": calls})
                else:
                    expected.append(message)
            expected.append(evidence)
        if messages != expected:
            errors.append(f"{path.name}: differs from task + previous state + latest observation projection")
        calls = [i["call_id"] for m in messages for i in m.get("provider_items", []) if i["type"] == "function_call"]
        outputs = [m["native_call_id"] for m in messages if m.get("native_call_id")]
        if sorted(calls) != sorted(outputs) or len(calls) != len(set(calls)):
            errors.append(f"{path.name}: native call/output pairing mismatch")
        if any(i["type"] != "function_call" for m in messages for i in m.get("provider_items", [])):
            errors.append(f"{path.name}: retained provider reasoning or text")
    return errors


def repeated_read_candidates(events: list[dict]) -> list[dict]:
    """Exact unchanged read repeats are review candidates, not semantic failures."""
    seen, candidates = {}, []
    for event in events:
        result = event.get("result")
        if event.get("name") != "read" or not isinstance(result, dict) or result.get("is_error"):
            continue
        key = (event.get("args", {}).get("path"), result.get("content", ""))
        if key in seen:
            candidates.append({"path": event.get("args", {}).get("path"), "first_call": seen[key], "repeated_call": event.get("call_id")})
        else:
            seen[key] = event.get("call_id")
    return candidates


def analyze(root: Path, seed: int) -> dict:
    rows, cells = [], defaultdict(list)
    for path in sorted(root.glob("*/run-config.json")):
        config = json.loads(path.read_text())
        if config.get("theory") != "state_only_pilot" or config.get("order_seed") != seed:
            continue
        directory = path.parent
        row = {"directory": str(directory), "scenario": config["scenario"]["id"], "variant": config["variant"]["id"], "run": config["run_number"]}
        result_path = directory / "result.json"
        if not result_path.exists():
            row["status"] = "unfinished_or_runner_timeout"
        else:
            if (directory / "result-reviewed.json").exists():
                result_path = directory / "result-reviewed.json"
            result = json.loads(result_path.read_text())
            row.update(status="pass" if result.get("passed") else "fail", metrics=result.get("metrics", {}))
            row["grading_review"] = result.get("grading_review")
            trajectory = json.loads((directory / "trajectory.json").read_text())
            row["protocol_errors"] = trajectory.get("context_pilot", {}).get("errors", [])
            row["state_updates"] = trajectory.get("context_pilot", {}).get("updates", 0)
            row["request_count"] = len(list(directory.glob("request-*.json")))
            row["repeated_read_candidates"] = repeated_read_candidates(trajectory.get("events", []))
            row["audit_errors"] = audit_state_only(directory) if row["variant"] == "state_only" else []
        rows.append(row)
        cells[f"{row['scenario']}/{row['variant']}"].append(row)
    summaries = {}
    for key, entries in cells.items():
        finished = [r for r in entries if r["status"] in ("pass", "fail")]
        summary = {"runs": len(entries), "finished": len(finished), "passed": sum(r["status"] == "pass" for r in finished),
                   "protocol_failures": sum(bool(r["protocol_errors"]) for r in finished),
                   "audit_failures": sum(bool(r["audit_errors"]) for r in finished)}
        for metric in ("estimated_total_api_cost_usd", "elapsed_ms", "prompt_tokens", "cached_tokens", "output_tokens", "llm_calls", "tool_calls"):
            values = [r["metrics"][metric] for r in finished if metric in r["metrics"]]
            if values:
                summary[metric + "_median"] = statistics.median(values)
                summary[metric + "_sum"] = sum(values)
        summaries[key] = summary
    return {"seed": seed, "runs": len(rows), "cells": summaries, "runs_detail": rows,
            "interpretation": "Descriptive short-task pilot. Failed/aborted runs remain in cost totals; early-stop cost is not an efficiency win. Repeated reads require semantic review."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--results", type=Path, default=Path(__file__).parent / "results")
    args = parser.parse_args()
    print(json.dumps(analyze(args.results, args.seed), indent=2))
