#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path


IGNORED_PARTS = {".git", "__pycache__", ".pytest_cache"}


def workspace_hashes(root: Path) -> dict[str, str]:
    hashes = {}
    for path in root.rglob("*"):
        if path.is_file() and not IGNORED_PARTS.intersection(path.parts):
            hashes[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def normalize_events(raw_events: list[dict]) -> tuple[list[dict], list[dict], int]:
    """Translate Codex JSONL items into the same action lifecycle LCA records."""
    events: list[dict] = []
    usage: list[dict] = []
    agent_messages = 0
    for raw in raw_events:
        if raw.get("type") == "turn.completed" and isinstance(raw.get("usage"), dict):
            item = raw["usage"]
            usage.append({
                "prompt_tokens": int(item.get("input_tokens", 0)),
                "cached_tokens": int(item.get("cached_input_tokens", 0)),
                "cache_write_tokens": int(item.get("cache_write_input_tokens", 0)),
                "output_tokens": int(item.get("output_tokens", 0)),
            })
        if raw.get("type") not in ("item.started", "item.completed") or not isinstance(raw.get("item"), dict):
            continue
        item = raw["item"]
        phase = "start" if raw["type"] == "item.started" else "result"
        if item.get("type") == "agent_message" and phase == "result":
            agent_messages += 1
        elif item.get("type") == "command_execution":
            exit_code = item.get("exit_code")
            event = {
                "phase": phase,
                "name": "command_execution",
                "args": {"command": item.get("command", "")},
                "action_id": item.get("id"),
            }
            if phase == "result":
                event["result"] = {
                    "content": item.get("aggregated_output", ""),
                    "aggregated_output": item.get("aggregated_output", ""),
                    "is_error": exit_code not in (0, None),
                    "exit_code": exit_code,
                }
            events.append(event)
        elif item.get("type") == "file_change":
            event = {
                "phase": phase, "name": "file_change", "args": item,
                "action_id": item.get("id"),
            }
            if phase == "result":
                event["result"] = {
                    "content": json.dumps(item),
                    "is_error": item.get("status") == "failed",
                }
            events.append(event)
    return events, usage, agent_messages


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Codex CLI and normalize its trajectory for LCA eval graders")
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--transcript", required=True)
    parser.add_argument("--model")
    parser.add_argument("--reasoning")
    args = parser.parse_args()

    workspace = Path.cwd()
    output = Path(args.output)
    transcript = Path(args.transcript)
    final_path = output.with_name("codex-final.txt")
    before = workspace_hashes(workspace)
    command = [
        "codex", "exec", "-C", str(workspace), "--sandbox", "danger-full-access",
        "--ephemeral", "--skip-git-repo-check", "--json",
        "--output-last-message", str(final_path),
    ]
    if args.model:
        command.extend(["--model", args.model])
    if args.reasoning:
        command.extend(["-c", f'model_reasoning_effort="{args.reasoning}"'])
    command.append("-")

    started = time.monotonic()
    completed = subprocess.run(
        command, input=Path(args.prompt_file).read_text(), text=True,
        capture_output=True, timeout=600,
    )
    elapsed_ms = round((time.monotonic() - started) * 1000)
    transcript.write_text(completed.stdout)
    transcript.with_suffix(transcript.suffix + ".stderr").write_text(completed.stderr)

    raw_events = []
    for line in completed.stdout.splitlines():
        try:
            raw_events.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    events, usage, agent_messages = normalize_events(raw_events)

    after = workspace_hashes(workspace)
    changed_paths = sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))
    if changed_paths and not any(event["name"] == "file_change" for event in events):
        events.append({
            "phase": "start", "name": "mutation", "args": {"paths": changed_paths},
            "action_id": "workspace-diff",
        })
        events.append({
            "phase": "result", "name": "mutation", "args": {"paths": changed_paths},
            "action_id": "workspace-diff",
            "result": {"content": "workspace changed", "is_error": False},
        })

    final = final_path.read_text() if final_path.exists() else ""
    trajectory = {
        "ok": completed.returncode == 0,
        "engine": "codex_cli",
        "model": args.model,
        "reasoning_effort": args.reasoning,
        "final": final,
        "tool_calls": sum(
            event.get("phase") == "result"
            and event["name"] in ("command_execution", "file_change", "mutation")
            for event in events
        ),
        "llm_calls": 1,
        "llm_calls_observable": False,
        "agent_messages": agent_messages,
        "elapsed_ms": elapsed_ms,
        "usage": usage,
        "events": events,
        "changed_paths": changed_paths,
        "returncode": completed.returncode,
        "stderr": completed.stderr[-4000:],
    }
    output.write_text(json.dumps(trajectory, indent=2) + "\n")
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
