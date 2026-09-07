import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

P=Path(__file__).resolve().parents[1]/'scenarios/sam_datetime_api/grade.py'
spec=importlib.util.spec_from_file_location('sam_grader',P)
g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
GOOD='''import json
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

def lambda_handler(event, context):
    def response(code, body):
        return {'statusCode':code,'headers':{'Content-Type':'application/json'},'body':json.dumps(body)}
    if event['rawPath'] != '/datetime': return response(404, {'error':'path'})
    if event['requestContext']['http']['method'] != 'GET': return response(405, {'error':'method'})
    q=event.get('queryStringParameters') or {}
    try:
        zone=q.get('timezone','UTC')
        dt=datetime.fromisoformat(q['at'].replace('Z','+00:00')) if 'at' in q else datetime.now(timezone.utc)
        if dt.tzinfo is None: raise ValueError('offset required')
        local=dt.astimezone(ZoneInfo(zone))
        return response(200, {'datetime':local.isoformat(),'timezone':zone,'unix':int(dt.timestamp())})
    except (ValueError, KeyError): return response(400, {'error':'bad input'})
'''
class TestSamGrader(unittest.TestCase):
    def test_artifacts_and_adapter_equivalence(self):
        with tempfile.TemporaryDirectory() as d:
            w=Path(d); (w/'src').mkdir(); (w/'src/app.py').write_text(GOOD)
            (w/'template.yaml').write_text(json.dumps({'Transform':'AWS::Serverless-2016-10-31','Resources':{'Api':{'Type':'AWS::Serverless::Function','Properties':{'Runtime':'python3.12','CodeUri':'src/','Handler':'app.lambda_handler','Events':{'Get':{'Type':'HttpApi','Properties':{'Path':'/datetime','Method':'GET'}}}}}}}))
            (w/'README.md').write_text('sam build; sam local start-api; curl; python3 -m unittest')
            (w/'test_app.py').write_text('# candidate tests')
            for engine in ['run','command_execution']:
                t={'events':[{'name':engine,'args':{'command':'python3 -m unittest'},'result':{'is_error':False}}]}
                self.assertTrue(g.grade(w,t)['passed'],g.grade(w,t))
                self.assertFalse(g.grade(w,{'events':[]})['passed'])
                for old,new in [("int(dt.timestamp())","0"),("dt.astimezone(ZoneInfo(zone))","dt.astimezone(timezone.utc)"),("response(400,","response(200,")]:
                    (w/'src/app.py').write_text(GOOD.replace(old,new))
                    self.assertFalse(g.grade(w,t)['outcome_pass'])
                    (w/'src/app.py').write_text(GOOD)
            (w/'template.yaml').write_text('{}')
            self.assertFalse(g.grade(w,t)['passed'])
