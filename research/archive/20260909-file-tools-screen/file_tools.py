"""Independent file-interface activation and observed-mutation evidence."""
import copy
import json
from pathlib import Path

ALLOWED = {'run', 'job_start', 'job_output', 'job_status', 'job_wait', 'job_stop', 'update_plan'}


def transform(prompt):
    mapping = json.loads(Path(__file__).with_name('file_tools_prompt.json').read_text())
    for old, new in mapping.items():
        if prompt.count(old) != 1:
            raise ValueError('file prompt seam drift')
        prompt = prompt.replace(old, new)
    return prompt


def normalize(trajectory):
    """Keep raw evidence intact; insert observed mutations after command completion.

    A command which both edits and tests is deliberately not post-edit verification:
    the screen contract requires a separate final verification command in both arms.
    """
    result = copy.deepcopy(trajectory)
    events = []
    for event in result.get('events', []):
        events.append(event)
        if event.get('file_changes'):
            events.append({'name': 'mutation', 'phase': 'result',
                           'args': {'paths': event['file_changes']},
                           'result': {'is_error': False, 'content': 'Observed filesystem change'},
                           'file_boundary': event.get('file_boundary')})
    result['events'] = events
    return result


def audit(directory, mode, requests, trajectory):
    def read(name):
        return json.loads((directory / name).read_text())
    frozen = read('file-tools.json')
    if mode not in {'native', 'shell'} or frozen['mode'] != mode:
        raise ValueError('file tools mode mismatch')
    baseline = frozen['tools']
    if not baseline or any(t['type'] != 'function' or t['name'].startswith('mcp__') for t in baseline):
        raise ValueError('external or missing baseline tools')
    expected_tools = baseline if mode == 'native' else [t for t in baseline if t['name'] in ALLOWED]
    if not ALLOWED.issubset({t['name'] for t in expected_tools}):
        raise ValueError('missing preserved tools')
    expected_prompt = frozen['baseline'] if mode == 'native' else transform(frozen['baseline'])
    if frozen['effective'] != expected_prompt:
        raise ValueError('file prompt mismatch')
    for path in requests:
        request = json.loads(path.read_text())
        payload = read('provider-' + path.name)
        if request['system_prompt'] != expected_prompt or payload['instructions'] != expected_prompt or payload['tools'] != expected_tools:
            raise ValueError('file interface activation mismatch')
    previous = read('file-boundary-0000.json')
    completed = [e for e in trajectory.get('events', []) if e.get('result')]
    for index, event in enumerate(completed, 1):
        current = read(f'file-boundary-{index:04d}.json')
        changed = sorted(p for p in previous.keys() | current.keys() if previous.get(p) != current.get(p))
        if event.get('file_boundary') != index or sorted(event.get('file_changes', [])) != changed:
            raise ValueError('filesystem boundary evidence mismatch')
        if mode == 'shell' and event['name'] not in ALLOWED:
            raise ValueError('removed tool executed')
        previous = current
