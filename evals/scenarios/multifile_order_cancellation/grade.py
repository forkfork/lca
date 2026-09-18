"""Version-2 behavioral grading. Tool sequence is measured, never a quality gate."""
from __future__ import annotations

import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from grader_support import successful_test_evidence


def grade(workspace, trajectory):
    workspace=Path(workspace)
    fixture=Path(__file__).with_name('fixture')
    env=dict(os.environ, ORDER_WORKSPACE=str(workspace.resolve()), PYTHONDONTWRITEBYTECODE='1')
    def run(command):
        try:
            # -B disables writes, but still accepts an existing .pyc. A fresh
            # cache prefix ensures every probe executes the candidate SOURCE.
            with tempfile.TemporaryDirectory(prefix='order-grader-cache-') as cache:
                result=subprocess.run(command,cwd=workspace,env=dict(env, PYTHONPYCACHEPREFIX=cache),
                                      text=True,capture_output=True,timeout=90)
            return result.returncode==0,(result.stdout+result.stderr)[-16000:]
        except subprocess.TimeoutExpired:
            return False,'Independent grader timed out after 90 seconds'
    public_ok,public_output=run([sys.executable,'-B','-m','unittest','discover','-s','tests','-v'])
    hidden_ok,hidden_output=run([sys.executable,'-B',str(Path(__file__).with_name('hidden_tests.py').resolve())])
    def files(root):
        return {p.relative_to(root).as_posix():p.read_bytes() for p in root.rglob('*')
                if p.is_file() and not {'__pycache__','.pytest_cache','.lca','.git'}.intersection(p.relative_to(root).parts)}
    original,actual=files(fixture),files(workspace)
    changed=sorted(name for name,body in original.items() if actual.get(name)!=body)
    added=sorted(set(actual)-set(original))
    scope=bool(changed) and all(name.startswith('orders/') and name.endswith('.py') and name in actual for name in changed)
    scope=scope and all(name.startswith(('orders/','tests/')) and name.endswith('.py') for name in added)
    # Keep migrations append-only, including their SQL, regardless of formatting.
    import ast
    def migration_one(text):
        tree=ast.parse(text)
        for node in tree.body:
            if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='MIGRATIONS' for t in node.targets):
                return ast.literal_eval(node.value)[0]
        raise ValueError('missing MIGRATIONS')
    try:
        migration_preserved=migration_one(original['orders/migrations.py'].decode())==migration_one(actual['orders/migrations.py'].decode())
    except (KeyError,ValueError,SyntaxError,TypeError): migration_preserved=False
    events=[e for e in trajectory.get('events',[]) if e.get('result')]
    mutations=[i for i,e in enumerate(events) if e.get('name') in {'apply_patch','edit','multi_edit','write','file_change','mutation'} and not e['result'].get('is_error')]
    last_mutation=max(mutations,default=-1)
    starts={}
    verified=False
    for i,e in enumerate(events):
        if e.get('name')=='job_start':
            job=e['result'].get('job',{});starts[job.get('id')]=(i,e.get('args',{}).get('command',''))
        if i<=last_mutation: continue
        if e.get('name') in {'run','shell','command_execution'} and successful_test_evidence(e):
            verified=True
        if e.get('name') in {'job_wait','job_output'}:
            start,command=starts.get(e.get('args',{}).get('id'),(-1,''))
            content=e['result'].get('content','')
            if start>last_mutation and 'status: exited' in content and 'exit_code: 0' in content:
                verified |= successful_test_evidence({'args':{'command':command},'result':e['result']})
    changed_lines=sum(sum(line.startswith(('- ','+ ')) for line in difflib.ndiff(
        original[n].decode(errors='replace').splitlines(),actual.get(n,b'').decode(errors='replace').splitlines())) for n in changed)
    gates={'public_regressions_and_examples':public_ok,'hidden_cancellation_contract':hidden_ok,
           'scope_preserved':bool(scope),'added_regression_tests':any(n.startswith('tests/test_') and n.endswith('.py') for n in added),'version_one_migration_preserved':migration_preserved,
           'observed_full_verification_after_final_edit':bool(verified and mutations)}
    return {'passed':all(gates.values()),'score':100*sum(gates.values())/len(gates),'hard_gates':gates,
            'evidence':{'fixture_version':2,'artifact_correct':public_ok and hidden_ok,'changed_files':changed,'added_files':added,
                        'changed_lines':changed_lines,'mutation_calls':len(mutations),
                        'edit_calls':sum(e.get('name')=='edit' for e in events),
                        'multi_edit_calls':sum(e.get('name')=='multi_edit' for e in events),
                        'write_calls':sum(e.get('name')=='write' for e in events),
                        'failed_mutations':sum(e.get('name') in {'apply_patch','edit','multi_edit','write'} and bool(e['result'].get('is_error')) for e in events),
                        'public_test_output':public_output,'hidden_test_output':hidden_output}}


if __name__=='__main__':
    print(json.dumps(grade(Path(sys.argv[1]),json.loads(Path(sys.argv[2]).read_text()))))
