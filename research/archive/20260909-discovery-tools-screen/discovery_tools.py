"""Audit the discovery-only ablation against exact serialized provider requests."""
import json
from pathlib import Path

REMOVED = {'ls', 'find', 'grep'}
PRESERVED = {'read', 'edit', 'write', 'run', 'update_plan', 'job_start', 'job_status', 'job_output', 'job_wait', 'job_stop'}


def transform(prompt):
    for old, new in json.loads(Path(__file__).with_name('discovery_tools_prompt.json').read_text()).items():
        if prompt.count(old) != 1:
            raise ValueError('discovery prompt seam drift')
        prompt = prompt.replace(old, new)
    return prompt


def audit(directory, mode, requests, trajectory):
    frozen = json.loads((directory / 'discovery-tools.json').read_text())
    if mode not in {'native', 'shell'} or frozen['mode'] != mode:
        raise ValueError('discovery mode mismatch')
    baseline = frozen['tools']
    names = {tool['name'] for tool in baseline}
    if not (REMOVED | PRESERVED).issubset(names) or any(t['type'] != 'function' or t['name'].startswith('mcp__') for t in baseline):
        raise ValueError('discovery baseline mismatch')
    expected = baseline if mode == 'native' else [t for t in baseline if t['name'] not in REMOVED]
    prompt = frozen['baseline'] if mode == 'native' else transform(frozen['baseline'])
    if frozen['effective'] != prompt or not requests:
        raise ValueError('discovery prompt mismatch')
    for path in requests:
        request = json.loads(path.read_text())
        body = json.loads((directory / ('provider-' + path.name)).read_text())
        if request['system_prompt'] != prompt or body['instructions'] != prompt or body['tools'] != expected:
            raise ValueError('discovery activation mismatch')
    for event in trajectory.get('events', []):
        if mode == 'shell' and event.get('result') and event['name'] in REMOVED:
            raise ValueError('removed discovery tool executed')
