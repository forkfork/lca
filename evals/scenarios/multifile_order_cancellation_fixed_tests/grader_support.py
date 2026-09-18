from __future__ import annotations
import re


def successful_test_evidence(event: dict) -> bool:
    command = str(event.get('args', {}).get('command', ''))
    # Require the documented full-suite invocation, not a command containing 'test'.
    if not re.search(r'\bpython[\d.]*\s+(?:-B\s+)?-m\s+unittest\s+discover\s+-s\s+tests\b', command):
        return False
    content = str(event.get('result', {}).get('content', ''))
    return bool(re.search(r'Ran\s+[1-9]\d*\s+tests?\b', content)
                and re.search(r'^OK\s*$', content, re.M)
                and not re.search(r'^FAILED\b', content, re.M))
