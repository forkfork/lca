"""Independent wire/activation audit for the tagged vs OpenAI patch screen."""
import json

SUBSTITUTIONS = [
    ('- For edits, inspect the target with read or tagged grep evidence first, then use its exact line numbers and four-character tags. Make the smallest coherent change and run focused verification.',
     '- For edits, inspect the target with read or grep first, then use apply_patch with contextual diff hunks. Read/grep line numbers and four-character tags are display labels: omit them from patch content. Make the smallest coherent change and run focused verification.'),
    ('- Batch independent inspection calls when useful. Do not call read and edit/write for the same file in parallel.',
     '- Batch independent inspection calls when useful. Do not call read and apply_patch/write for the same file in parallel.'),
    ('- After inspection, batch non-overlapping tagged edits whose replacements are all known.',
     '- After inspection, combine known non-overlapping changes in one file into one apply_patch operation with multiple contextual hunks.'),
    ('- Group known import and body replacements against the same inspected file version. An earlier insertion can shift later line numbers: do not submit a later edit using tags from before that insertion. Batch independent replacements together; re-read before a dependent edit.',
     '- Group known import and body replacements against the same inspected file version. Use unchanged context to locate each hunk; re-read before a dependent edit when its context is uncertain.'),
]


PATCH_SPEC = {
    'type': 'function', 'name': 'apply_patch', 'strict': False,
    'description': 'Apply an OpenAI V4A contextual diff. Use update_file for existing files (diff with @@ hunks, space context, - removals, + additions); create_file uses + lines; delete_file needs only path. Do not include Begin/End Patch wrappers or read/grep display labels. Multiple hunks in one file are applied together and checked for syntax before writing.',
    'parameters': {'type': 'object', 'properties': {
        'type': {'type': 'string', 'enum': ['create_file', 'update_file', 'delete_file']},
        'path': {'type': 'string'}, 'diff': {'type': 'string'}},
        'required': ['type', 'path'], 'additionalProperties': False},
}


def read(path):
    return json.loads(path.read_text())


def audit(directory, arm, requests, trajectory):
    if arm not in {'tagged', 'openai_patch_fixed_tests'}:
        raise ValueError('unknown edit interface')
    snapshot = read(directory / 'edit-interface.json')
    if snapshot['profile'] != arm or trajectory.get('edit_tool_profile') != arm:
        raise ValueError('edit profile mismatch')
    baseline = snapshot['baseline_tools']
    if sum(t.get('name') == 'edit' for t in baseline) != 1 or any(t.get('type') != 'function' or t.get('name') == 'multi_edit' for t in baseline):
        raise ValueError('invalid tagged baseline')
    expected_tools = baseline
    expected_prompt = snapshot['baseline_prompt']
    if arm == 'openai_patch_fixed_tests':
        expected_tools = [PATCH_SPEC if t.get('name') == 'edit' else t for t in baseline]
        for old, new in SUBSTITUTIONS:
            if expected_prompt.count(old) != 1:
                raise ValueError('missing unique baseline instruction')
            expected_prompt = expected_prompt.replace(old, new)
    if snapshot['effective_tools'] != expected_tools or snapshot['effective_prompt'] != expected_prompt:
        raise ValueError('edit schema/prompt transform mismatch')
    payloads = sorted(directory.glob('provider-request-*.json'))
    if not requests or len(payloads) != len(requests):
        raise ValueError('missing wire evidence')
    native_calls = {}
    outputs = {}
    for request_path, payload_path in zip(requests, payloads):
        payload = read(payload_path)
        tools = expected_tools + ([{'type': 'web_search'}] if (trajectory.get('tool_scope') or 'all') == 'all' else [])
        if payload_path.name != 'provider-' + request_path.name or payload.get('tools') != tools or payload.get('instructions') != expected_prompt:
            raise ValueError('outgoing edit interface mismatch')
        if read(request_path)['system_prompt'] != expected_prompt:
            raise ValueError('request prompt mismatch')
        calls_in_payload = {}
        results_in_payload = {}
        for item in payload['input']:
            if item.get('type') == 'function_call' and item.get('name') == 'apply_patch':
                calls_in_payload[item['call_id']] = item
                native_calls[item['call_id']] = item
            elif item.get('type') == 'function_call_output' and item['call_id'] in calls_in_payload:
                results_in_payload[item['call_id']] = item
                outputs[item['call_id']] = item
        if set(calls_in_payload) != set(results_in_payload):
            raise ValueError('unpaired patch history')
    events = [e for e in trajectory.get('events', []) if e.get('result') is not None]
    edits = [e for e in events if e.get('name') in {'edit', 'multi_edit', 'apply_patch'}]
    expected_name = 'apply_patch' if arm == 'openai_patch_fixed_tests' else 'edit'
    if any(e['name'] != expected_name for e in edits):
        raise ValueError('wrong edit tool executed')
    for event in edits:
        if arm == 'openai_patch_fixed_tests':
            call_id = event['call_id']
            if json.loads(native_calls.get(call_id, {}).get('arguments', 'null')) != event['args']:
                raise ValueError('patch operation missing from replay')
            if event['result'].get('content', '') not in outputs.get(call_id, {}).get('output', ''):
                raise ValueError('patch result content mismatch')
    config = read(directory / 'run-config.json')
    if config['scenario']['id'] == 'simple_prompt' and events:
        raise ValueError('simple control unexpectedly used tools')
    if config['scenario']['id'] == 'multifile_order_cancellation_fixed_tests':
        if not any(not e['result'].get('is_error') for e in edits):
            raise ValueError('editing interface did not activate')
        # This screen requires observed edits to existing source, not whole-file
        # writes or shell rewrites. Supplied tests must remain untouched.
        for event in events:
            name, args = event.get('name'), event.get('args', {})
            if name in {'edit', 'multi_edit', 'apply_patch'}:
                if not args.get('path', '').startswith('orders/') or (name == 'apply_patch' and args.get('type') != 'update_file'):
                    raise ValueError('mutation outside existing production source')
            if name == 'write':
                raise ValueError('source write bypass')
            if name in {'run', 'job_start'} and args.get('command', '').strip() not in {
                'python3 -m unittest discover -s tests -v',
                'python3 -B -m unittest discover -s tests -v',
            }:
                raise ValueError('unaudited shell command: ' + args.get('command', ''))
