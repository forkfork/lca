"""Independent artifact/receipt grading and actual-request activation audit."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

COMMAND = "python3 -B -m unittest discover -s tests -v"
MARKER = "<operational-state>"


def files(root):
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*")
            if p.is_file() and not {"__pycache__", ".pytest_cache"}.intersection(p.parts)}


def grade(workspace, trajectory, fixture):
    actual, original = files(workspace), files(fixture)
    scope = set(actual) == set(original) and all(actual[n] == body for n, body in original.items() if n != "invoice.py")
    probe = subprocess.run([sys.executable, "-B", "-c",
        "from invoice import total\nfor s, t in [(0,0),(1,99),(999,7),(10000,10),(12345,23)]:\n assert total(s,t) == s + s*t//100, (s,t,total(s,t))"],
        cwd=workspace, capture_output=True, text=True, timeout=10)
    final_hash = hashlib.sha256(actual.get("invoice.py", b"")).hexdigest()
    receipts = [e for e in trajectory.get("events", []) if e.get("name") == "run"
                and e.get("args", {}).get("command", "").strip() == COMMAND
                and e.get("result") and not e["result"].get("is_error")
                and "\nOK" in e["result"].get("content", "")
                and e.get("workspace_sha256") == final_hash]
    gates = {"artifact_correct": probe.returncode == 0, "scope_preserved": scope,
             "verified_submitted_version": bool(receipts)}
    return {"passed": all(gates.values()), "score": sum(gates.values()) * 100 / 3,
            "hard_gates": gates, "evidence": {"verification_receipts": len(receipts),
            "final_sha256": final_hash, "probe_output": (probe.stdout + probe.stderr)[-2000:]}}


def audit(directory, arm, requests, trajectory):
    seed = json.loads((directory / "operational-screen.json").read_text())
    report = trajectory.get("operational_screen") or {}
    if seed["arm"] != arm or report.get("arm") != arm or report.get("scenario") != seed["scenario"]:
        raise ValueError("operational intervention activation mismatch")
    coding = seed["scenario"] != "simple_prompt"
    if seed["compacted"] != coding or report.get("compacted") != coding:
        raise ValueError("compaction did not activate")
    if coding:
        events = seed["events"]
        finishes = [e for e in events if e.get("phase") == "finish"]
        if seed["scenario"] == "stale_pass":
            if [e["name"] for e in finishes] != ["run", "write"] or any(e["result"].get("is_error") for e in finishes):
                raise ValueError("invalid stale-pass setup")
            if '"name":"write"' not in seed["checkpoint"]:
                raise ValueError("later write not recorded")
        else:
            if [e["name"] for e in finishes] != ["write", "run", "run"] or not finishes[1]["result"].get("is_error") or finishes[2]["result"].get("is_error"):
                raise ValueError("invalid unresolved-failure setup")
            if '"outcome":"failed"' not in seed["checkpoint"]:
                raise ValueError("unresolved failure not recorded")
    payloads = sorted(directory.glob("provider-request-*.json"))
    if len(payloads) != len(requests):
        raise ValueError("missing serialized requests")
    for index, (request_path, payload_path) in enumerate(zip(requests, payloads)):
        request = json.loads(request_path.read_text())
        payload = json.loads(payload_path.read_text())
        rendered = json.dumps(payload, ensure_ascii=False)
        has_state = any(MARKER in m.get("text", "") for m in request["messages"])
        if arm == "without_state" and (has_state or MARKER in rendered):
            raise ValueError("control leaked operational state")
        if arm == "with_state" and coding and (not has_state or MARKER not in rendered):
            raise ValueError("treatment missing operational state")
        if index == 0 and coding:
            if seed["summary"] not in request["messages"][0]["text"]:
                raise ValueError("frozen summary missing")
            if arm == "with_state":
                # Compare decoded message strings, never infer activation from labels.
                contents = [c.get("text", "") for m in payload.get("input", []) for c in m.get("content", []) if isinstance(c, dict)]
                if seed["checkpoint"] not in contents:
                    raise ValueError("seed checkpoint not present in provider request")
