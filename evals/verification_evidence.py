"""Recognize completed unittest evidence, not attempted commands or final claims."""
import re

SUMMARY = re.compile(r"(?m)^Ran [1-9]\d* tests?(?: in [^\r\n]+)?\r?\n(?:[ \t]*\r?\n)*(OK|FAILED[^\r\n]*)[ \t]*(?:\r?\n|$)")
MUTATIONS = {"edit", "multi_edit", "write", "file_change", "mutation"}
COMMANDS = {"run", "shell", "command_execution"}


def successful_unittest(event):
    if event.get("name") not in COMMANDS:
        return False
    command = str(event.get("args", {}).get("command", ""))
    if "unittest" not in command and not re.search(r"(?:^|[\s;&])check(?:$|[\s;&])", command):
        return False
    result = event.get("result") or {}
    content = str(result.get("content", ""))
    summaries = list(SUMMARY.finditer(content))
    if not summaries or summaries[-1][1] != "OK":
        return False
    if not result.get("is_error"):
        return True
    tail = content[summaries[-1].end():]
    return "git diff" in command and "not a git repository" in tail.lower() and "Traceback (most recent call last)" not in tail


def verified_after_mutations(events):
    last_mutation = max((i for i, event in enumerate(events)
                         if event.get("name") in MUTATIONS and event.get("result")
                         and not event["result"].get("is_error")), default=-1)
    return any(i > last_mutation and successful_unittest(event) for i, event in enumerate(events))
