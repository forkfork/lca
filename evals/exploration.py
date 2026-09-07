"""Append-only exploration records and explicitly gated, conditional promotion.

Evidence is supplied by an external evaluator, never by the acting model's
confidence. The store checks consistency/provenance, not the evaluator's honesty.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
from pathlib import Path
import statistics


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, allow_nan=False)


def sha(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def nonempty(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("expected nonempty text")
    return value


class Ledger:
    def __init__(self, directory):
        self.directory = Path(directory)

    def events(self):
        events = []
        previous = None
        for path in sorted(self.directory.glob("[0-9]*.json")):
            item = json.loads(path.read_text())
            checksum = item.pop("sha256")
            if checksum != sha(item) or item["previous"] != previous or item["sequence"] != len(events):
                raise ValueError("ledger chain changed")
            item["sha256"] = checksum
            events.append(item)
            previous = checksum
        return events

    def append(self, kind, payload):
        self.directory.mkdir(parents=True, exist_ok=True)
        with (self.directory / ".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            events = self.events()
            body = json.loads(canonical(payload))
            self.validate(kind, body, events)
            event = {"sequence": len(events), "previous": events[-1]["sha256"] if events else None,
                     "kind": kind, "payload": body}
            event["sha256"] = sha(event)
            # A partial write is detected as corruption and never silently skipped.
            with (self.directory / f"{len(events):06d}.json").open("x") as stream:
                stream.write(canonical(event) + "\n")
                stream.flush()
                import os
                os.fsync(stream.fileno())
            return event

    def validate(self, kind, body, events):
        if kind == "observation":
            for key in ("id", "task_id", "family", "question", "hypothesis", "intervention", "judgment"):
                nonempty(body.get(key))
            if any(e["payload"].get("id") == body["id"] for e in events):
                raise ValueError("duplicate record id")
            if not isinstance(body.get("observation"), dict) or not body["observation"]:
                raise ValueError("missing measurements")
            confidence = body.get("confidence")
            if isinstance(confidence, bool) or not isinstance(confidence, (float, int)) or not 0 <= confidence <= 1:
                raise ValueError("confidence must be in [0,1]")
            self.check_evidence(body)
        elif kind == "candidate":
            for key in ("id", "lesson", "condition", "family", "metric"):
                nonempty(body.get(key))
            if any(e["payload"].get("id") == body["id"] for e in events):
                raise ValueError("duplicate record id")
            observations = {e["payload"]["id"]: e["payload"] for e in events if e["kind"] == "observation"}
            origins = body.get("observations", [])
            if not origins or any(i not in observations for i in origins):
                raise ValueError("candidate requires existing observations")
            if any(observations[i]["family"] != body["family"] for i in origins):
                raise ValueError("candidate crosses task families")
            validation = body.get("validation_tasks", [])
            heldout = body.get("evaluation_tasks", [])
            discovery = {record["task_id"] for record in observations.values()}
            if len(validation) < 5 or len(set(validation)) != len(validation) or not heldout or len(set(heldout)) != len(heldout):
                raise ValueError("register at least five distinct validation tasks and held-out evaluation tasks")
            if any(not isinstance(i, str) or not i for i in validation + heldout):
                raise ValueError("task ids must be nonempty strings")
            if set(validation) & (discovery | set(heldout)) or discovery & set(heldout):
                raise ValueError("discovery, validation and evaluation tasks must be disjoint")
            rule = body["rule"]
            if rule.get("direction") not in {"lower", "higher"}:
                raise ValueError("unknown metric direction")
            for key in ("minimum_median_gain", "maximum_regression"):
                value = rule.get(key)
                if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or not 0 <= value < 1:
                    raise ValueError("invalid promotion threshold")
        elif kind == "validation":
            candidate = self.candidate(body["candidate"], events)
            if body["task_id"] not in candidate["validation_tasks"] or body["family"] != candidate["family"]:
                raise ValueError("validation is not in the registered cohort")
            if any(e["kind"] == "validation" and e["payload"]["candidate"] == body["candidate"] and e["payload"]["task_id"] == body["task_id"] for e in events):
                raise ValueError("duplicate validation task; no best-of retries")
            self.check_evidence(body)
            # The evidence artifact is the external evaluator's paired result.
            proof = body["evidence"][0]["content"]
            for key in ("task_id", "family", "candidate"):
                if proof.get(key) != body[key]:
                    raise ValueError("validation evidence identity mismatch")
            if proof.get("metric") != candidate["metric"]:
                raise ValueError("validation metric mismatch")
            for key in ("fixture_sha256", "grader_sha256", "model", "reasoning", "control_run", "treatment_run"):
                nonempty(proof.get(key))
            if proof["control_run"] == proof["treatment_run"]:
                raise ValueError("validation requires paired independent runs")
            previous_runs = {proof_id for e in events if e["kind"] == "validation" and e["payload"]["candidate"] == body["candidate"]
                             for proof_id in (e["payload"]["evidence"][0]["content"]["control_run"], e["payload"]["evidence"][0]["content"]["treatment_run"])}
            if previous_runs & {proof["control_run"], proof["treatment_run"]}:
                raise ValueError("validation run reused across task ids")
            for key in ("before", "after"):
                if isinstance(proof.get(key), bool) or not isinstance(proof.get(key), (int, float)) or not math.isfinite(proof[key]) or proof[key] <= 0:
                    raise ValueError("paired measurements must be finite and positive")
            if not isinstance(proof.get("control_passed"), bool) or not isinstance(proof.get("treatment_passed"), bool):
                raise ValueError("external correctness grades required")
        elif kind == "promotion":
            candidate = self.candidate(body["candidate"], events)
            if any(e["kind"] == "promotion" and e["payload"]["candidate"] == body["candidate"] for e in events):
                raise ValueError("already promoted")
            judgment = self.assess(body["candidate"], events)
            if not judgment["eligible"]:
                raise ValueError("promotion rejected: " + judgment["reason"])
            body.clear()
            body.update(candidate=candidate["id"], lesson=candidate["lesson"], condition=candidate["condition"],
                        family=candidate["family"], validation=judgment)
        else:
            raise ValueError("unknown ledger event")

    @staticmethod
    def check_evidence(body):
        evidence = body.get("evidence", [])
        if not evidence:
            raise ValueError("evidence required")
        for item in evidence:
            nonempty(item.get("source"))
            if sha(item["content"]) != item.get("sha256"):
                raise ValueError("evidence hash mismatch")

    @staticmethod
    def candidate(identifier, events):
        for event in events:
            if event["kind"] == "candidate" and event["payload"]["id"] == identifier:
                return event["payload"]
        raise ValueError("unknown candidate")

    def assess(self, identifier, events=None):
        events = self.events() if events is None else events
        candidate = self.candidate(identifier, events)
        validations = [e["payload"] for e in events if e["kind"] == "validation" and e["payload"]["candidate"] == identifier]
        if {v["task_id"] for v in validations} != set(candidate["validation_tasks"]):
            return {"eligible": False, "reason": "registered validation cohort incomplete"}
        gains = []
        for record in validations:
            proof = record["evidence"][0]["content"]
            if not proof["control_passed"] or not proof["treatment_passed"]:
                return {"eligible": False, "reason": "paired correctness gate failed"}
            gain = (proof["before"] - proof["after"]) / proof["before"]
            gains.append(gain if candidate["rule"]["direction"] == "lower" else -gain)
        eligible = statistics.median(gains) >= candidate["rule"]["minimum_median_gain"] and min(gains) >= -candidate["rule"]["maximum_regression"]
        return {"eligible": eligible, "reason": "registered thresholds met" if eligible else "effect/regression gate failed",
                "gains": gains, "median_gain": statistics.median(gains), "tasks": [v["task_id"] for v in validations]}

    def blind(self):
        observations = [e["payload"] for e in self.events() if e["kind"] == "observation"]
        return [{key: o[key] for key in ("task_id", "family", "question", "intervention", "observation")} |
                {"evidence_hashes": [e["sha256"] for e in o["evidence"]]} for o in observations]

    def views(self, raw_trajectories):
        events = self.events()
        observations = [e["payload"] for e in events if e["kind"] == "observation"]
        candidates = [e["payload"] for e in events if e["kind"] == "candidate"]
        promotions = [e["payload"] for e in events if e["kind"] == "promotion"]
        validations = [e["payload"] for e in events if e["kind"] == "validation"]
        # No copied file paths or evidence content in the blind view: those could
        # expose conclusions. Reference only content hashes plus measured facts.
        blind = self.blind()
        learned_tasks = {o["task_id"] for o in observations}
        for candidate in candidates:
            learned_tasks.update(candidate["validation_tasks"])
        if not isinstance(raw_trajectories, list) or {r["task_id"] for r in raw_trajectories} != learned_tasks:
            raise ValueError("raw corpus must cover exactly the same discovery and registered validation tasks")
        if len(raw_trajectories) != len(learned_tasks):
            raise ValueError("duplicate raw task trajectories")
        if any(not r.get("trajectory") for r in raw_trajectories):
            raise ValueError("raw corpus needs actual trajectories, not task labels")
        distilled = [{k: v for k, v in o.items() if k != "evidence"} |
                     {"evidence": [{"sha256": e["sha256"], "source": e["source"]} for e in o["evidence"]]} for o in observations]
        return {"version": 1, "ledger_sha256": events[-1]["sha256"] if events else None,
                "excluded_tasks": sorted(learned_tasks), "promoted_count": len(promotions),
                "evaluation_tasks": sorted(set.intersection(*(set(c["evaluation_tasks"]) for c in candidates))) if candidates else [],
                "views": {"none": "", "raw": canonical(raw_trajectories),
                          "ledger": canonical({"observations": distilled, "candidates": candidates,
                                               "validation_measurements": [v["evidence"][0]["content"] for v in validations]}),
                          "promoted": canonical(promotions), "blind": canonical(blind)}}


def evidence(path):
    content = json.loads(Path(path).read_text())
    return {"source": str(path), "content": content, "sha256": sha(content)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("action", choices=["observation", "candidate", "validation", "promote", "assess", "export"])
    parser.add_argument("input", help="record JSON, candidate id, or raw-trajectory JSON for export")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    ledger = Ledger(args.directory)
    if args.action in {"promote", "assess"}:
        result = ledger.assess(args.input) if args.action == "assess" else ledger.append("promotion", {"candidate": args.input})
    elif args.action == "export":
        result = ledger.views(json.loads(Path(args.input).read_text()))
    else:
        body = json.loads(Path(args.input).read_text())
        if "evidence_files" in body:
            body["evidence"] = [evidence(p) for p in body.pop("evidence_files")]
        result = ledger.append(args.action, body)
    if args.output:
        with args.output.open("x") as stream:
            stream.write(canonical(result) + "\n")
    else:
        print(canonical(result))


if __name__ == "__main__":
    main()
