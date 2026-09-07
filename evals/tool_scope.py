"""Audit the hosted-search-only ablation from serialized outbound payloads."""
import json


def read(path):
    return json.loads(path.read_text())


def audit(directory, scope, requests, trajectory):
    if scope not in {"all", "local_only"}:
        raise ValueError("unsupported tool scope")
    baseline = read(directory / "tool-scope-baseline.json")["tools"]
    if not baseline or baseline[-1] != {"type": "web_search"}:
        raise ValueError("missing hosted tool baseline")
    native = baseline[:-1]
    if not native or any(t.get("type") != "function" for t in native):
        raise ValueError("invalid native tool baseline")
    expected = baseline if scope == "all" else native
    payloads = sorted(directory.glob("provider-request-*.json"))
    if len(payloads) != len(requests):
        raise ValueError("missing serialized provider requests")
    if (trajectory.get("tool_scope") or "all") != scope:
        raise ValueError("trajectory tool scope mismatch")
    for request_path, payload_path in zip(requests, payloads):
        if payload_path.name != "provider-" + request_path.name:
            raise ValueError("provider request index mismatch")
        request, payload = read(request_path), read(payload_path)
        if request.get("tool_scope") != scope or payload.get("tools") != expected:
            raise ValueError("tool scope activation/schema mismatch")
        if payload.get("model") != request["model"] or payload.get("instructions") != request["system_prompt"]:
            raise ValueError("provider model/prompt mismatch")
        if payload.get("reasoning", {}).get("effort") != request["reasoning_effort"]:
            raise ValueError("provider reasoning mismatch")
        if payload.get("tool_choice") != "auto" or payload.get("parallel_tool_calls") is not True:
            raise ValueError("provider tool policy mismatch")
