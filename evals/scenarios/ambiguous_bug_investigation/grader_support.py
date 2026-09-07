import re


def successful_test_evidence(event):
    command = str(event.get("args", {}).get("command", "")).lower()
    if not any(term in command for term in ("unittest", "pytest")):
        return False
    result = event.get("result", {})
    if not result.get("is_error"):
        return True
    content = str(result.get("content", ""))
    # A failed trailing Git inspection must not erase a completed test run.
    # Do not forgive failing tests or an unresolved Python verification probe.
    return bool(
        "git diff" in command
        and "not a git repository" in content.lower()
        and re.search(r"(?m)^Ran \d+ tests? in [^\n]+\n\s*\nOK\s*(?:\n|$)", content)
        and "FAILED" not in content
        and "Traceback (most recent call last)" not in content
    )
