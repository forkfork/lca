from __future__ import annotations
import importlib.util
import json
from pathlib import Path
import re
import sys
from datetime import datetime, timezone
import yaml

class Loader(yaml.SafeLoader):
    pass
Loader.add_multi_constructor('!', lambda loader, tag, node: loader.construct_scalar(node) if isinstance(node, yaml.ScalarNode) else loader.construct_sequence(node) if isinstance(node, yaml.SequenceNode) else loader.construct_mapping(node))

def grade(workspace, trajectory):
    checks, errors = {}, {}
    def check(name, fn):
        try:
            assert fn()
            checks[name] = True
        except Exception as exc:
            checks[name] = False
            errors[name] = repr(exc)
    def template():
        t = yaml.load((workspace/'template.yaml').read_text(), Loader=Loader)
        assert t['Transform'] == 'AWS::Serverless-2016-10-31'
        fs = [v['Properties'] for v in t['Resources'].values() if v['Type']=='AWS::Serverless::Function']
        return any(f.get('Runtime')=='python3.12' and f.get('CodeUri','').rstrip('/')=='src' and f.get('Handler')=='app.lambda_handler' and any(e.get('Type')=='HttpApi' and e.get('Properties',{}).get('Path')=='/datetime' and e['Properties'].get('Method','').upper()=='GET' for e in f.get('Events',{}).values()) for f in fs)
    check('sam_template', template)
    try:
        sys.path.insert(0,str(workspace/'src'))
        spec=importlib.util.spec_from_file_location('candidate_app',workspace/'src/app.py')
        app=importlib.util.module_from_spec(spec)
        exec(compile((workspace/'src/app.py').read_text(), str(workspace/'src/app.py'), 'exec'), app.__dict__)
        handler=app.lambda_handler
    except Exception as exc:
        handler=None
        errors['import']=repr(exc)
    def invoke(query=None,path='/datetime',method='GET',missing=False):
        event={'version':'2.0','rawPath':path,'requestContext':{'http':{'method':method,'path':path}}}
        if not missing: event['queryStringParameters']=query
        response=handler(event,None)
        assert isinstance(response['body'],str)
        assert 'application/json' in {k.lower():v for k,v in response.get('headers',{}).items()}['content-type']
        return response['statusCode'],json.loads(response['body'])
    def valid(at,zone):
        from zoneinfo import ZoneInfo
        status,body=invoke({'at':at,'timezone':zone})
        source=datetime.fromisoformat(at.replace('Z','+00:00'))
        got=datetime.fromisoformat(body['datetime'].replace('Z','+00:00'))
        expected=source.astimezone(ZoneInfo(zone))
        return status==200 and body['timezone']==zone and type(body['unix']) is int and body['unix']==int(source.timestamp()) and got==expected and got.utcoffset()==expected.utcoffset()
    for name,at,zone in [('utc','2024-02-29T23:59:59Z','UTC'),('summer','2024-01-15T00:00:00Z','Australia/Melbourne'),('winter','2024-07-15T00:00:00Z','Australia/Melbourne'),('dst_before','2024-03-10T06:59:59Z','America/New_York'),('dst_after','2024-03-10T07:00:00Z','America/New_York'),('offset','2024-02-29T12:34:56+05:45','Asia/Kathmandu')]:
        check(name,lambda at=at,zone=zone:valid(at,zone))
    def now(missing):
        before=datetime.now(timezone.utc).timestamp()
        status,b=invoke(missing=missing)
        after=datetime.now(timezone.utc).timestamp()
        parsed=datetime.fromisoformat(b['datetime'].replace('Z','+00:00'))
        return status==200 and b['timezone']=='UTC' and parsed.utcoffset().total_seconds()==0 and before-1<=parsed.timestamp()<=after+1 and type(b['unix']) is int and abs(b['unix']-parsed.timestamp())<1
    check('now_null',lambda:now(False)); check('now_missing',lambda:now(True))
    def default_zone():
        status,b=invoke({'at':'2024-01-01T00:00:00Z'})
        return status==200 and b['timezone']=='UTC' and b['unix']==1704067200
    check('default_timezone',default_zone)
    def bad(q=None,path='/datetime',method='GET',status=400):
        code,b=invoke(q,path,method)
        return code==status and isinstance(b.get('error'),str) and bool(b['error'].strip())
    for i,q in enumerate([{'timezone':'Mars/Olympus'},{'timezone':''},{'at':''},{'at':'oops'},{'at':'2024-01-01T12:00:00'},{'at':'2024-02-30T12:00:00Z'}]):
        check('invalid_'+str(i),lambda q=q:bad(q))
    check('not_found',lambda:bad(path='/missing',status=404))
    check('method',lambda:bad(method='POST',status=405))
    check('tests_exist',lambda:any(workspace.rglob('test*.py')))
    check('documentation',lambda:all(s in (workspace/'README.md').read_text().lower() for s in ['sam build','sam local start-api','curl','unittest']))
    commands=[e for e in trajectory.get('events',[]) if e.get('result') and e.get('name') in {'run','shell','command_execution'}]
    verified=any(not e['result'].get('is_error') and re.search(r'\b(?:unittest|pytest)\b',str(e.get('args',{}).get('command',''))) for e in commands)
    return {'passed':all(checks.values()) and verified,'outcome_pass':all(checks.values()),'evidence_pass':verified,'score':round(90*sum(checks.values())/len(checks))+10*verified,'hard_gates':dict(checks,verification=verified),'evidence':{'errors':errors}}

if __name__=='__main__':
    print(json.dumps(grade(Path(sys.argv[1]),json.loads(Path(sys.argv[2]).read_text()))))
