"""Independent acceptance gates for fresh durable-job tasks."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).parent

def grade(workspace,trajectory,scenario):
    workspace=Path(workspace); fixture=ROOT/'scenarios'/scenario/'fixture'
    failure=scenario=='job_failure_recovery'
    source='inventory.py' if failure else 'labels.py'
    protected='build.py' if failure else 'worker.py'
    probe=("assert available(12,5)==7; assert available(3,9)==0; assert available(0,0)==0; assert available(8,8)==0" if failure else "assert label('  HeLLo  ')=='id: hello'; assert label(' X')=='id: x'; assert label('')=='id: '")
    code="from pathlib import Path; exec(compile(Path("+repr(source)+").read_text(),"+repr(source)+",'exec')); "+probe
    tested=subprocess.run([sys.executable,'-B','-c',code],cwd=workspace,capture_output=True,text=True,timeout=5)
    digest=hashlib.sha256((workspace/source).read_bytes()).hexdigest() if (workspace/source).exists() else ''
    scope=(workspace/protected).exists() and (workspace/protected).read_bytes()==(fixture/protected).read_bytes()
    allowed={source,protected,'.verified.json'} if failure else {source,protected,'.ready','.alpha.json','.beta.json'}
    scope=scope and all(p.name in allowed or p.parts[0] in {'.lca','__pycache__'} for p in (f.relative_to(workspace) for f in workspace.rglob('*') if f.is_file()))
    events=[e for e in trajectory.get('events',[]) if e.get('result')]
    jobs=[json.loads(p.read_text()) for p in workspace.glob('.lca/jobs/*/job.json')]
    commands=json.loads((ROOT/'scenarios'/scenario/'commands.json').read_text())
    def seen(job,text):
        return any(e.get('args',{}).get('id')==job['id'] and text in e['result'].get('content','') for e in events if e.get('name') in {'job_wait','job_output','job_status'})
    good=[j for j in jobs if j.get('command') in commands and j.get('status')=='exited' and j.get('exit_code')==0 and seen(j,'status: exited') and seen(j,'exit_code: 0')]
    terminal=all(j.get('status') not in {'starting','running'} for j in jobs)
    if failure:
        receipts=['.verified.json']
        success=any(seen(j,'BUILD VERIFIED') for j in good)
        bad=[j for j in jobs if j.get('command')==commands[0] and j.get('exit_code')==7 and seen(j,'BUILD ERROR:')]
        bad_ids={j['id'] for j in bad}
        first_failure=next((i for i,e in enumerate(events) if e.get('args',{}).get('id') in bad_ids and 'BUILD ERROR:' in e['result'].get('content','')),None)
        first_edit=next((i for i,e in enumerate(events) if e.get('name') in {'edit','multi_edit','write'} and str(e.get('args',{}).get('path','')).endswith(source)),None)
        workflow=first_failure is not None and first_edit is not None and first_failure<first_edit and success
    else:
        receipts=['.alpha.json','.beta.json']
        success=all(any(j['command']==command and seen(j,name+' VERIFIED') for j in good) for command,name in zip(commands,['alpha','beta']))
        starts=[i for i,e in enumerate(events) if e.get('name')=='job_start' and e.get('args',{}).get('command') in commands]
        edits=[i for i,e in enumerate(events) if e.get('name') in {'edit','multi_edit','write'} and str(e.get('args',{}).get('path','')).endswith(source)]
        workflow=len(starts)==2 and bool(edits) and max(starts)<min(edits) and success
    receipt_ok=True
    for name in receipts:
        try: r=json.loads((workspace/name).read_text()); receipt_ok &= r.get('sha256')==digest and r.get('passed') is True
        except (OSError,ValueError): receipt_ok=False
    gates={'artifact_correct':tested.returncode==0,'scope_preserved':scope,'verified_final_version':bool(receipt_ok),'workflow_and_observed_completion':bool(workflow),'no_abandoned_jobs':bool(jobs) and terminal}
    return {'passed':all(gates.values()),'score':100*sum(gates.values())/len(gates),'hard_gates':gates,'evidence':{'jobs':len(jobs),'probe':(tested.stdout+tested.stderr)[-2000:]}}
