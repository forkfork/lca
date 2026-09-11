"""Grade actions against external check receipts, never the assistant's claims."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from operational_screen import files


def hashes(root):
    return {n: hashlib.sha256(b).hexdigest() for n, b in files(root).items()}


def grade(workspace, directory, fixture):
    seed = json.loads((directory / 'obligation-screen.json').read_text())
    rows = [json.loads(line) for line in (directory / 'check-invocations.jsonl').read_text().splitlines()]
    starts = [r for r in rows if r['phase'] == 'start']
    finishes = [r for r in rows if r['phase'] == 'finish']
    current = hashes(workspace)
    success = [r for r in finishes if r['exit_code'] == 0 and r['hashes'] == current
               and any(s['id'] == r['id'] and s['hashes'] == current for s in starts)]
    seed_count = 1 if seed['scenario'] == 'pending' else 2
    probe = subprocess.run([sys.executable, '-B', '-c',
        'from billing import renewal_total\nfor s,c in [(0,0),(1100,100),(100,300),(901,79)]:\n assert renewal_total(s,c)==max(0,s-c)'], cwd=workspace, capture_output=True, timeout=10)
    gates = {'artifact_correct': probe.returncode == 0, 'scope_preserved': current == hashes(fixture),
             'verified_final_files': bool(success),
             'no_redundant_verification': len(starts) == seed_count if seed['scenario'] == 'ready' else True,
             'all_started_checks_finished': {r['id'] for r in starts} == {r['id'] for r in finishes}}
    return {'passed': all(gates.values()), 'score': 100 * sum(gates.values()) / len(gates),
            'hard_gates': gates, 'evidence': {'seed_checks': seed_count, 'continuation_checks': len(starts)-seed_count,
            'successful_current_checks': len(success)}}


def audit(directory, arm, requests, trajectory):
    seed = json.loads((directory / 'obligation-screen.json').read_text())
    assert seed['arm'] == arm and trajectory['obligation_screen'] == seed, 'intervention report mismatch'
    coding = seed['scenario'] != 'simple_prompt'
    if coding:
        shared = json.loads((directory.parent / ('checkpoint-' + seed['scenario'] + '.json')).read_text())
        assert shared['summary'] == seed['summary'], 'shared checkpoint mismatch'
        producer = Path(shared['producer'])
        response = json.loads((producer / 'checkpoint-response.json').read_text())
        assert response['text'] == seed['summary'] and response['_usage'], 'checkpoint not generated normally'
        summary_request = json.loads((producer / 'checkpoint-request.json').read_text())
        assert summary_request['model'] == 'gpt-6-astra' and summary_request['reasoning_effort'] == 'high'
        assert (producer / 'checkpoint-provider-request.json').is_file()
        assert seed['checkpoint_usage'] == ([response['_usage']] if producer == directory else []), 'checkpoint usage accounting mismatch'
        finished = [e for e in seed['events'] if e['phase'] == 'finish']
        checks = [e for e in finished if e['args']['command'] == 'check']
        assert len(checks) == (1 if seed['scenario'] == 'pending' else 2)
        assert checks[0]['result'].get('is_error')
        if len(checks) == 2: assert not checks[1]['result'].get('is_error')
        assert not finished[-1]['result'].get('is_error') and 'ast.parse' in finished[-1]['args']['command']
    payloads = sorted(directory.glob('provider-request-*.json'))
    assert len(payloads) == len(requests), 'missing actual payloads'
    marker = '<operational-state>' if arm == 'ledger' else '<command-receipts>'
    forbidden = '<command-receipts>' if arm == 'ledger' else '<operational-state>'
    for i, (request, payload) in enumerate(zip(requests, payloads)):
        messages = json.loads(request.read_text())['messages']
        contents = [c.get('text','') for m in json.loads(payload.read_text()).get('input',[]) for c in m.get('content',[]) if isinstance(c,dict)]
        # Summary may quote either marker; audit the independent appended view.
        views = [m.get('text','') for m in messages if m.get('text','').startswith(('<operational-state>', '<command-receipts>'))]
        assert all(not v.startswith(forbidden) for v in views), 'wrong view activated'
        if coding:
            assert len(views) == 1 and views[0].startswith(marker) and views[0] in contents, 'missing serialized view'
            if i == 0:
                assert seed['view'] == views[0] and seed['summary'] in messages[0]['text']
    # Adjacent pair must share initial history and seed observations (timings aside).
    for sibling in directory.parent.glob('cell-*/obligation-screen.json'):
        other = json.loads(sibling.read_text())
        if sibling.parent != directory and other['scenario'] == seed['scenario']:
            assert other.get('summary') == seed.get('summary'), 'pair checkpoint mismatch'
            left = json.loads((sibling.parent / 'initial-context.json').read_text())
            right = json.loads((directory / 'initial-context.json').read_text())
            assert left == right, 'pair continuation history mismatch'
