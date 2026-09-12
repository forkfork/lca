import json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from first_run import configure
class FirstRunTests(unittest.TestCase):
 def test_prepared_image_reused_without_build_or_message(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)/'config.json';cfg={'image_arn':'ready','checkpoint_bucket':'bucket'};p.write_text(json.dumps(cfg))
   with patch('first_run.setup',return_value=cfg),patch('first_run.api') as api,patch('handoff.aws') as aws:
    messages=[];self.assertEqual(configure(p,messages.append),cfg)
    self.assertEqual(messages,[]);api.assert_not_called();aws.assert_not_called()
 def test_first_build_and_interrupted_wait_reuse_same_image(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)/'config.json'
   def api(cfg,service,*args):
    if service=='sts':return {'Account':'123456789012','Arn':'arn:aws:iam::123456789012:user/test'}
    if args[0]=='get-role':return {'Role':{'Arn':'arn:aws:iam::123456789012:role/'+args[-1]}}
    return {}
   calls=[]
   def aws(cfg,op,*args):
    calls.append(op)
    if op=='create-microvm-image':return {'imageArn':'image','imageVersion':'1.0'}
    raise RuntimeError('network interruption')
   with patch('first_run.api',side_effect=api),patch('first_run.setup',side_effect=lambda c:{**c,'checkpoint_bucket':'bucket'}),patch('first_run.s3'),patch('first_run.subprocess.run'),patch('handoff.aws',side_effect=aws):
    with self.assertRaisesRegex(RuntimeError,'network interruption'):configure(p,lambda _:None)
   self.assertEqual(calls.count('create-microvm-image'),1)
   saved=json.loads(p.read_text());self.assertIn('pending_image',saved);self.assertNotIn('image_arn',saved)
   with patch('first_run.api',side_effect=api),patch('first_run.setup',side_effect=lambda c:c),patch('first_run.s3') as s3,patch('handoff.aws',return_value={'state':'SUCCESSFUL','status':'ACTIVE'}) as aws:
    cfg=configure(p,lambda _:None)
    self.assertEqual(cfg['image_arn'],'image');self.assertEqual(cfg['image_version'],'1.0')
    self.assertNotIn('pending_image',cfg);s3.assert_not_called()
    self.assertEqual(aws.call_count,1)
 def test_uncertain_create_reuses_persisted_token(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)/'config.json'
   request={'clientToken':'same-token','name':'same-image'}
   p.write_text(json.dumps({'setup_id':'one','image_name':'same-image','execution_role_arn':'arn:aws:iam::123456789012:role/run','build_role_arn':'arn:aws:iam::123456789012:role/build','checkpoint_bucket':'bucket','image_build_request':request}))
   with patch('first_run.api',return_value={'Account':'123456789012','Arn':'arn:aws:iam::123456789012:user/test'}),patch('first_run.setup',side_effect=lambda c:c),patch('handoff.aws',side_effect=[{'imageArn':'image','imageVersion':'1.0'},{'state':'SUCCESSFUL','status':'ACTIVE'}]) as aws:
    configure(p,lambda _:None)
    self.assertEqual(json.loads(aws.call_args_list[0].args[-1]),request)
