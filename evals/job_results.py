"""Frozen response-format audit and independent job-artifact grader."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def executable(command):
    # The fixture's single padding comment is deliberately non-executable.
    return '\n'.join(line for line in command.splitlines() if not line.startswith('# verification-context')).strip()


def grade(workspace, trajectory):
    workspace = Path(workspace)
    command = (Path(__file__).parent / 'scenarios/job_receipt/verify-command.txt').read_text()
    probe = subprocess.run([sys.executable, '-B', '-c', "from summarize import total; assert total([])==0; assert total([{'status':'ok','amount':9},{'status':'failed','amount':50},{'status':'pending','amount':7},{'status':'ok','amount':-3}])==6"], cwd=workspace, capture_output=True, text=True, timeout=5)
    digest = hashlib.sha256((workspace / 'summarize.py').read_bytes()).hexdigest()
    receipt = workspace / '.receipt'
    jobs = [json.loads(p.read_text()) for p in workspace.glob('.lca/jobs/*/job.json')]
    verified = [j for j in jobs if executable(j.get('command', '')) == executable(command) and j.get('status') == 'exited' and j.get('exit_code') == 0 and 'VERIFIED' in (workspace / '.lca/jobs' / j['id'] / 'stdout.log').read_text()]
    events = [e for e in trajectory.get('events', []) if e.get('result')]
    observed = any(e.get('name') == 'job_wait' and e.get('args', {}).get('id') in {j['id'] for j in verified} and 'status: exited' in e['result'].get('content', '') and 'exit_code: 0' in e['result'].get('content', '') and 'VERIFIED' in e['result'].get('content', '') for e in events)
    scope = all(p.name in {'summarize.py', 'verify.py', '.receipt'} or p.parts[0] in {'.lca', '__pycache__'} for p in (f.relative_to(workspace) for f in workspace.rglob('*') if f.is_file()))
    scope = scope and (workspace / 'verify.py').is_file() and (workspace / 'verify.py').read_bytes() == (Path(__file__).parent / 'scenarios/job_receipt/fixture/verify.py').read_bytes()
    gates = {'artifact_correct': probe.returncode == 0, 'verified_final_version': receipt.exists() and receipt.read_text() == digest, 'observed_successful_job': observed, 'scope_preserved': scope}
    return {'passed': all(gates.values()), 'score': 100 * sum(gates.values()) / len(gates), 'hard_gates': gates, 'evidence': {'probe': (probe.stdout + probe.stderr)[-2000:], 'successful_jobs': len(verified)}}


def audit(directory, arm, requests, trajectory):
    if trajectory.get('job_results') != arm:
        raise ValueError('job-results activation mismatch')
    payloads = [json.loads(p.read_text()) for p in sorted(directory.glob('provider-request-*.json'))]
    if len(payloads) != len(requests):
        raise ValueError('missing job-results request evidence')
    events = [e for e in trajectory.get('events', []) if e.get('result') and e.get('name') in {'job_start','job_wait','job_status','job_output'}]
    starts = [e for e in events if e['name'] == 'job_start']
    if directory.joinpath('run-config.json').exists():
        config = json.loads((directory / 'run-config.json').read_text())
        if config.get('scenario', {}).get('id') == 'job_receipt' and not starts:
            raise ValueError('job-results treatment never exercised')
    if directory.joinpath('run-config.json').exists() and config.get('scenario', {}).get('id') in {'job_failure_recovery','job_overlap_edit'}:
        return audit_fresh(arm, requests, payloads, events, starts)
    command = (Path(__file__).parent / 'scenarios/job_receipt/verify-command.txt').read_text()
    commands = [e['result'].get('job', {}).get('command', '') for e in starts]
    if starts and not all(len(c) >= 8000 and c == command for c in commands):
        raise ValueError('oversized command fixture did not activate')
    for event in events:
        content = event['result'].get('content', '')
        if event['result'].get('is_error'):
            continue
        if any(c in content for c in commands) != (arm == 'full_command'):
            raise ValueError('job result command format mismatch')
        # Audit actual serialized outputs, not just intervention labels.
        if not any(content in text for payload in payloads for text in strings(payload)):
            raise ValueError('job result missing from outgoing provider request')
    for payload, request_path in zip(payloads, requests):
        request = json.loads(request_path.read_text())
        if payload.get('instructions') != request['system_prompt'] or payload.get('tools') != payloads[0].get('tools'):
            raise ValueError('prompt/schema changed during job result ablation')


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)


def audit_fresh(arm, requests, payloads, events, starts):
    commands={e['result'].get('job',{}).get('id'):e['result'].get('job',{}).get('command') for e in starts if not e['result'].get('is_error')}
    if not commands or any(not command or len(command)<=160 for command in commands.values()):
        raise ValueError('fresh job formatter not exercised')
    for e in events:
        if e['result'].get('is_error'): continue
        job_id=e['result'].get('job',{}).get('id') if e['name']=='job_start' else e.get('args',{}).get('id')
        command=commands.get(job_id)
        if not command: raise ValueError('job result has no matching start')
        compact=' '.join(command.split());compact=compact[:157]+'...' if len(compact)>160 else compact
        expected=command if arm=='full_command' else compact
        body=e['result'].get('content','')
        if 'command: '+expected+'\n' not in body and not body.endswith('command: '+expected):
            raise ValueError('fresh command format mismatch')
        if not any(body in text for payload in payloads for text in strings(payload)):
            raise ValueError('fresh job result absent from provider request')
    for payload,request_path in zip(payloads,requests):
        request=json.loads(request_path.read_text())
        if payload.get('instructions')!=request['system_prompt'] or payload.get('tools')!=payloads[0].get('tools'):
            raise ValueError('fresh prompt/schema drift')
