"""Durable, serial experiment campaigns. No model calls during plan creation."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import random
import signal
import subprocess
import sys
import time

import run
from analyze_state_pilot import audit_state_only

ROOT = Path(__file__).resolve().parent.parent
# Only interventions for which this runner has an activation contract are admitted.
VARIANT_KEYS = {"id", "model", "reasoning", "context_mode", "experience_mode", "experience_bundle", "lesson_policy", "system_prompt_profile", "tool_scope", "operational_context", "obligation_view"}


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def source_digest():
    result = hashlib.sha256()
    for directory in ("lua", "bin", "scripts", "evals", "tests"):
        for path in sorted((ROOT / directory).rglob("*")):
            relative = path.relative_to(ROOT)
            if not path.is_file() or any(part in {"results", "__pycache__", ".pytest_cache"} for part in relative.parts):
                continue
            result.update(str(relative).encode() + b"\0" + path.read_bytes() + b"\0")
    for name in ("AGENTS.md", "Makefile", "lca-dev-1.rockspec"):
        result.update(name.encode() + (ROOT / name).read_bytes())
    return result.hexdigest()


def plan(theory, smoke, repetitions, seed, max_runs, max_cost, max_seconds):
    screen = theory.get("study_kind") == "screen"
    if screen and (repetitions != 1 or len(theory["variants"]) != 2 or len(theory["scenarios"]) not in {2, 3}
                   or len(set(theory["scenarios"])) != len(theory["scenarios"]) or "simple_prompt" not in theory["scenarios"]):
        raise ValueError("screen requires two arms, one repetition, and simple_prompt plus one or two coding tasks")
    if repetitions < int(theory["minimum_runs_per_cell"]):
        raise ValueError("repetitions cannot undercut the registered minimum")
    if not smoke or not set(smoke).issubset(theory["scenarios"]):
        raise ValueError("smoke scenarios must be a nonempty subset of the theory")
    if "simple_prompt" not in smoke or len(set(smoke)) < 2:
        raise ValueError("smoke requires simple_prompt and a coding scenario")
    suffixes = theory.get("task_suffixes", {})
    if not isinstance(suffixes, dict) or not set(suffixes).issubset(theory["scenarios"]) or any(not isinstance(value, str) or not value for value in suffixes.values()):
        raise ValueError("task suffixes must map registered scenarios to nonempty strings")
    for variant in theory["variants"]:
        unknown = set(variant) - VARIANT_KEYS
        if unknown:
            raise ValueError(f"no activation contract for variant keys: {sorted(unknown)}")
        if variant.get("model") not in run.MODEL_PRICES or variant.get("reasoning") not in {"low", "medium", "high", "xhigh", "max"}:
            raise ValueError("each variant must pin a supported model and reasoning")
        if variant["reasoning"] == "max" and variant["model"] != "gpt-6-astra":
            raise ValueError("max reasoning requires Astra")
        if variant.get("context_mode", "normal") not in {"normal", "state_only", "state_history"}:
            raise ValueError("unsupported context mode")
        if "system_prompt_profile" in variant:
            from prompt_profiles import PROFILES
            if variant["system_prompt_profile"] not in PROFILES or variant.get("context_mode", "normal") != "normal":
                raise ValueError("unsupported audited prompt/context combination")
        if "tool_scope" in variant and (variant["tool_scope"] not in {"all", "local_only"} or variant.get("context_mode", "normal") != "normal"):
            raise ValueError("unsupported audited tool scope")
        if "obligation_view" in variant:
            if variant["obligation_view"] not in {"ledger", "receipts"} or variant.get("context_mode", "normal") != "normal" or "operational_context" in variant:
                raise ValueError("unsupported obligation view")
        if "operational_context" in variant:
            if variant["operational_context"] not in {"with_state", "without_state"} or variant.get("context_mode", "normal") != "normal":
                raise ValueError("unsupported operational context intervention")
        if "experience_mode" in variant or "experience_bundle" in variant:
            from experience_context import load
            for task in theory["scenarios"]:
                load(variant, task)
        if "lesson_policy" in variant:
            if "experience_mode" in variant:
                raise ValueError("cannot mix experience interventions")
            from lesson_gate import load
            for task in theory["scenarios"]:
                load(variant["lesson_policy"], task)
    if max_runs < 1 or not all(math.isfinite(v) and v > 0 for v in (max_cost, max_seconds)):
        raise ValueError("budgets must be finite and positive")
    rng = random.Random(seed)
    cells = []
    if screen:
        tasks = [task for task in theory["scenarios"] if task != "simple_prompt"]
        rng.shuffle(tasks)
        # Adjacent randomized pairs reduce drift and replace duplicated smoke /
        # pilot collection. These cells can never support a promotion decision.
        for scenario in ["simple_prompt"] + tasks:
            pair = [{"stage": "screen", "scenario": scenario, "variant": variant, "repetition": 1}
                    for variant in theory["variants"]]
            rng.shuffle(pair)
            cells.extend(pair)
    stages = [] if screen else [("smoke", list(dict.fromkeys(smoke)), 1), ("pilot", theory["scenarios"], repetitions)]
    for stage, scenarios, count in stages:
        batch = [{"stage": stage, "scenario": scenario, "variant": variant,
                  "repetition": repetition} for repetition in range(1, count + 1)
                 for scenario in scenarios for variant in theory["variants"]]
        rng.shuffle(batch)
        cells.extend(batch)
    for index, cell in enumerate(cells):
        cell["id"] = f"cell-{index:04d}"
        if cell["scenario"] in suffixes:
            cell["task_suffix"] = suffixes[cell["scenario"]]
    return {"version": 1, "theory": theory, "seed": seed, "cells": cells,
            "decision_scope": "screen_only" if screen else theory.get("study_kind", "comparison"),
            "source_sha256": source_digest(), "max_runs": max_runs,
            "max_estimated_cost_usd": max_cost, "max_seconds": max_seconds,
            "concurrency": 1, "cost_limit_kind": "between-run standard-equivalent threshold; may overshoot by one run"}


def inspect_result(directory, cell):
    result = read(directory / "result.json")
    config = read(directory / "run-config.json")
    trajectory = read(directory / "trajectory.json")
    variant = cell["variant"]
    if config["model"] != variant["model"] or config["reasoning"] != variant["reasoning"]:
        raise ValueError("model/reasoning activation mismatch")
    pilot = trajectory.get("context_pilot") or {}
    mode = variant.get("context_mode", "normal")
    if pilot.get("mode") != mode:
        raise ValueError("context intervention did not activate")
    if pilot.get("errors") or trajectory.get("error") or result.get("error"):
        raise ValueError("run/protocol failure: " + str(trajectory.get("error") or result.get("error") or pilot["errors"]))
    if mode != "normal" and (not pilot.get("responses") or pilot.get("updates") != pilot.get("responses")):
        raise ValueError("state response/update count mismatch")
    requests = sorted(directory.glob("request-*.json"))
    if not requests or len(requests) != pilot.get("requests"):
        raise ValueError("missing request evidence")
    if "task_suffix" in cell:
        _, original = run.load_scenarios()[cell["scenario"]]
        expected_task = original["prompt"] + cell["task_suffix"]
        if config["scenario"]["prompt"] != expected_task:
            raise ValueError("task contract snapshot mismatch")
        messages = read(requests[0]).get("messages", [])
        if not any(m.get("role") == "user" and m.get("text") == expected_task + "\n" for m in messages):
            raise ValueError("task contract injection mismatch")
    for request_path in requests:
        request = read(request_path)
        if (request.get("model"), request.get("reasoning_effort"), request.get("context_mode")) != (variant["model"], variant["reasoning"], mode):
            raise ValueError("outgoing request activation mismatch")
    if "experience_mode" in variant:
        from experience_context import load, PREFIX
        expected = load(variant, cell["scenario"])
        if read(directory / "experience.json") != expected:
            raise ValueError("experience snapshot mismatch")
        first = read(requests[0])
        injected = [m.get("text", "") for m in first["messages"] if m.get("role") == "user" and m.get("text", "").startswith(PREFIX)]
        if injected != ([expected["text"]] if expected["text"] else []):
            raise ValueError("experience injection did not activate correctly")
    if "system_prompt_profile" in variant:
        from prompt_profiles import audit
        audit(directory, variant["system_prompt_profile"], requests, trajectory)
    if "tool_scope" in variant:
        from tool_scope import audit as audit_tool_scope
        audit_tool_scope(directory, variant["tool_scope"], requests, trajectory)
    if "obligation_view" in variant:
        from obligation_discrimination import audit
        try:
            audit(directory, variant["obligation_view"], requests, trajectory)
        except AssertionError as exc:
            raise ValueError("obligation activation: " + str(exc)) from exc
    if "operational_context" in variant:
        from operational_screen import audit
        audit(directory, variant["operational_context"], requests, trajectory)
    if "lesson_policy" in variant:
        from lesson_gate import load, PREFIX
        expected = load(variant["lesson_policy"], cell["scenario"])
        if read(directory / "lesson-policy.json") != expected:
            raise ValueError("lesson-policy snapshot mismatch")
        first = read(requests[0])
        injected = [m.get("text", "") for m in first["messages"] if m.get("role") == "user" and m.get("text", "").startswith(PREFIX)]
        if injected != ([expected["text"]] if expected["text"] else []):
            raise ValueError("lesson-policy injection mismatch")
    if not pilot.get("responses") or len(trajectory.get("usage", [])) != pilot["responses"]:
        raise ValueError("incomplete per-response usage")
    if mode == "state_only":
        if not list(directory.glob("request-*.json")):
            raise ValueError("missing request evidence")
        errors = audit_state_only(directory)
        if errors:
            raise ValueError(str(errors))
    cost = result.get("metrics", {}).get("estimated_total_api_cost_usd")
    if not isinstance(cost, (float, int)) or not math.isfinite(cost) or cost < 0:
        raise ValueError("missing/invalid cost telemetry")
    return result


def worker(directory, index, credentials):
    manifest = read(directory / "manifest.json")
    cell = manifest["cells"][index]
    scenario_dir, config = run.load_scenarios()[cell["scenario"]]
    config = dict(config)
    config["prompt"] += cell.get("task_suffix", "")
    args = argparse.Namespace(model=cell["variant"]["model"], reasoning=cell["variant"]["reasoning"],
        seed=manifest["seed"], credentials=credentials, judge="none", judge_model=None,
        keep=True, result_dir=directory / cell["id"])
    variant = dict(cell["variant"])
    variant.setdefault("context_mode", "normal")
    run.run_once(scenario_dir, config, args, cell["repetition"], variant, manifest["theory"]["id"])


def execute(directory, credentials):
    with (directory / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest = read(directory / "manifest.json")
        state_path = directory / "state.json"
        state = read(state_path)
        if digest(manifest) != state["manifest_sha256"] or source_digest() != manifest["source_sha256"]:
            raise ValueError("manifest or source changed; create a new campaign")
        if state.get("halted"):
            raise ValueError("campaign halted: " + state["halted"])
        if state.get("running"):
            raise ValueError("interrupted cell requires evidence review; it will not be retried automatically")
        # Offline contract checks before any paid work, once per immutable campaign.
        if not state.get("preflight_passed"):
            with (directory / "preflight.log").open("w") as log:
                checked = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "evals/tests", "-p", "test_*.py"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=120)
            if checked.returncode:
                raise ValueError("offline preflight failed; see preflight.log")
            state["preflight_passed"] = True
            save(state_path, state)
        for index, cell in enumerate(manifest["cells"]):
            if cell["id"] in state["completed"]:
                continue
            if (directory / "stop-request.json").exists():
                state["halted"] = "operator requested stop between runs; completed evidence preserved"
                break
            if source_digest() != manifest["source_sha256"] or digest(read(directory / "manifest.json")) != state["manifest_sha256"]:
                raise ValueError("source or manifest changed during campaign")
            if len(state["completed"]) >= manifest["max_runs"] or state["estimated_cost_usd"] >= manifest["max_estimated_cost_usd"]:
                state["stop_reason"] = "run or estimated cost budget reached"
                break
            remaining = manifest["max_seconds"] - state["elapsed_seconds"]
            if remaining <= 0:
                state["stop_reason"] = "active execution time budget reached"
                break
            state["running"] = cell["id"]
            save(state_path, state)
            started = time.monotonic()
            print(f"{cell['stage']} {cell['id']} {cell['scenario']}/{cell['variant']['id']}", flush=True)
            with (directory / (cell["id"] + ".log")).open("w") as log:
                process = subprocess.Popen([sys.executable, __file__, "worker", str(directory), "--index", str(index), "--credentials", credentials], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    process.wait(timeout=remaining)
                except (subprocess.TimeoutExpired, KeyboardInterrupt):
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    # Unknown usage is never treated as zero or automatically retried.
                    state["halted"] = "worker interrupted; incomplete evidence/usage requires review"
            state["elapsed_seconds"] += time.monotonic() - started
            result_dir = directory / cell["id"]
            try:
                raw = read(result_dir / "result.json")
                cost = raw.get("metrics", {}).get("estimated_total_api_cost_usd")
                if isinstance(cost, (int, float)) and math.isfinite(cost) and cost >= 0:
                    state["estimated_cost_usd"] += cost
                result = inspect_result(result_dir, cell)
                if cell["stage"] in {"smoke", "screen"} and not result.get("passed"):
                    state["halted"] = cell["stage"] + " task failed; review before funding further runs"
                state["completed"][cell["id"]] = {"passed": bool(result.get("passed")), "stage": cell["stage"]}
            except (OSError, ValueError, KeyError, TypeError) as exc:
                state["halted"] = state.get("halted") or str(exc)
                state["completed"][cell["id"]] = {"passed": False, "stage": cell["stage"], "error": str(exc)}
            state.pop("running", None)
            save(state_path, state)
            if state.get("halted"):
                break
        state["complete"] = len(state["completed"]) == len(manifest["cells"]) and not state.get("halted")
        save(state_path, state)
        print(json.dumps(state, indent=2))
        return 0 if state["complete"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "run", "status", "stop", "worker"])
    parser.add_argument("directory", type=Path)
    parser.add_argument("--theory")
    parser.add_argument("--smoke", nargs="+", default=["simple_prompt", "ambiguous_bug_investigation"])
    parser.add_argument("--runs", type=int)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--max-runs", type=int, default=12)
    parser.add_argument("--max-cost", type=float, default=5)
    parser.add_argument("--max-seconds", type=float, default=1800)
    parser.add_argument("--credentials", default="~/.lca-credentials.json")
    parser.add_argument("--index", type=int)
    args = parser.parse_args()
    directory = args.directory.resolve()
    if args.action == "plan":
        theories = run.load_theories()
        run.validate_theories(theories, run.load_scenarios())
        theory = theories[args.theory]
        manifest = plan(theory, args.smoke, args.runs or theory["minimum_runs_per_cell"], args.seed, args.max_runs, args.max_cost, args.max_seconds)
        # Keep generated state outside source trees included in the fingerprint.
        if not directory.is_relative_to(ROOT / "evals/results"):
            raise ValueError("campaign directory must be under evals/results")
        directory.mkdir(parents=True, exist_ok=False)
        save(directory / "manifest.json", manifest)
        save(directory / "state.json", {"manifest_sha256": digest(manifest), "completed": {}, "estimated_cost_usd": 0, "elapsed_seconds": 0})
        print(json.dumps(manifest, indent=2))
    elif args.action == "worker":
        worker(directory, args.index, args.credentials)
    elif args.action == "status":
        print(json.dumps(read(directory / "state.json"), indent=2))
    elif args.action == "stop":
        read(directory / "manifest.json")
        save(directory / "stop-request.json", {"reason": "operator requested stop after current run"})
        print("Stop requested; any current run will finish and retain its evidence.")
    else:
        return execute(directory, args.credentials)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, BlockingIOError) as exc:
        print(f"campaign: {exc}", file=sys.stderr)
        sys.exit(2)
