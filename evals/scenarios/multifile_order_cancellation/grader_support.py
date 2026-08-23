from __future__ import annotations


def successful_test_evidence(event: dict) -> bool:
    command = str(event.get("args", {}).get("command", "")).lower()
    if not any(term in command for term in ("unittest", "pytest", "test")):
        return False
    result = event.get("result", {})
    if not result.get("is_error"):
        return True
    # Codex often appends Git inspection to an otherwise-green compound command in
    # the non-Git eval workspace. Preserve the successful test subcommand evidence.
    content = str(result.get("content", ""))
    return "Ran " in content and "\nOK\n" in content and "FAILED" not in content
