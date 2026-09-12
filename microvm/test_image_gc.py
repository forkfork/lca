import copy,unittest
from image_gc import collect,plan,pages
class GC(unittest.TestCase):
 def setUp(self):
  self.cfg={'image_arn':'owned','image_version':'8.0','image_gc':{'image_arn':'owned','rollback_version':'7.0'}}
  self.versions={str(n)+'.0':{'imageVersion':str(n)+'.0','state':'SUCCESSFUL','status':'ACTIVE','createdAt':'2026-09-%02dT00:00:00+00:00'%n} for n in (1,2,3,7,8,9)}
  self.versions['2.0']['state']='FAILED';self.versions['2.0']['status']='INACTIVE'
  self.vms=[{'imageVersion':'3.0','state':'SUSPENDED'}];self.calls=[];self.race=False
 def aws(self,cfg,cmd,*args):
  self.calls.append((cmd,args))
  if cmd=='list-microvm-image-versions':return {'items':copy.deepcopy(list(self.versions.values()))}
  if cmd=='list-microvms':return {'items':copy.deepcopy(self.vms)}
  version=args[args.index('--image-version')+1];v=self.versions[version]
  if cmd=='get-microvm-image-version':return copy.deepcopy(v)
  if cmd=='update-microvm-image-version':
   v['status']=args[-1]
   if self.race and args[-1]=='INACTIVE':self.vms.append({'imageVersion':version,'state':'RUNNING'})
   return {}
  if cmd=='delete-microvm-image-version':
   self.assertEqual(v['status'],'INACTIVE');v['state']='DELETED';return {}
  raise AssertionError(cmd)
 def test_preview_protects_default_rollback_suspended_and_new_versions(self):
  r=collect(self.aws,self.cfg,emit=lambda _:None)
  self.assertEqual(r['candidates'],['1.0','2.0']);self.assertEqual(r['deleted'],[])
  self.assertTrue(all(c.startswith('list-') for c,_ in self.calls))
 def test_apply_retires_rechecks_then_confirms_deletion(self):
  r=collect(self.aws,self.cfg,True,emit=lambda _:None)
  self.assertEqual(r['deleted'],['1.0','2.0'])
  self.assertEqual(set(plan(self.aws,self.cfg)['keep']),{'3.0','7.0','8.0','9.0'})
 def test_launch_racing_retirement_is_kept_and_reactivated(self):
  self.race=True
  r=collect(self.aws,self.cfg,True,emit=lambda _:None)
  self.assertIn('1.0',r['skipped']);self.assertEqual(self.versions['1.0']['status'],'ACTIVE')
 def test_config_change_to_candidate_protects_it(self):
  def reload():
   cfg=copy.deepcopy(self.cfg)
   if self.versions['1.0']['status']=='INACTIVE':cfg['image_gc']['rollback_version']='1.0'
   return cfg
  # Stop after the first skip: the reactivated version remains a valid rollback.
  self.versions.pop('2.0')
  r=collect(self.aws,self.cfg,True,emit=lambda _:None,reload_config=reload)
  self.assertEqual(r['deleted'],[]);self.assertEqual(self.versions['1.0']['status'],'ACTIVE')
 def test_unknown_ownership_or_invalid_default_stops_before_mutation(self):
  self.cfg['image_gc']['image_arn']='different'
  with self.assertRaises(ValueError):plan(self.aws,self.cfg)
  self.assertEqual(self.calls,[])
  self.cfg['image_gc']['image_arn']='owned';self.versions['8.0']['state']='FAILED'
  with self.assertRaises(ValueError):collect(self.aws,self.cfg,True)
  self.assertFalse(any(c.startswith(('update-','delete-')) for c,_ in self.calls))
 def test_all_vm_pages_are_read(self):
  calls=[]
  def aws(cfg,cmd,*args):
   calls.append(args)
   return {'items':[2]} if '--next-token' in args else {'items':[1],'nextToken':'next'}
  self.assertEqual(pages(aws,{},'list-microvms'),[1,2]);self.assertEqual(len(calls),2)

class LocalOnly(unittest.TestCase):
 def test_no_config_never_accesses_aws(self):
  from image_gc import run
  from unittest.mock import Mock
  import tempfile
  from pathlib import Path
  aws=Mock();messages=[]
  with tempfile.TemporaryDirectory() as tmp:run(aws,Path(tmp)/'absent',True,messages.append)
  aws.assert_not_called();self.assertIn('not configured',messages[0])
 def test_no_gc_policy_never_accesses_aws(self):
  from image_gc import run
  from unittest.mock import Mock
  import tempfile,json
  from pathlib import Path
  aws=Mock()
  with tempfile.TemporaryDirectory() as tmp:
   path=Path(tmp)/'config';path.write_text(json.dumps({'image_arn':'other'}))
   run(aws,path,True,lambda _:None)
  aws.assert_not_called()
 def test_missing_credentials_is_nonfatal_and_no_mutations(self):
  from image_gc import run
  import tempfile,json
  from pathlib import Path
  cfg={'image_arn':'owned','image_version':'8.0','image_gc':{'image_arn':'owned','rollback_version':'7.0'}}
  calls=[];messages=[]
  def aws(cfg,command,*args):calls.append(command);raise RuntimeError('Unable to locate credentials')
  with tempfile.TemporaryDirectory() as tmp:
   path=Path(tmp)/'config';path.write_text(json.dumps(cfg));run(aws,path,True,messages.append)
  self.assertEqual(calls,['list-microvm-image-versions']);self.assertIn('credentials',messages[0])
 def test_cli_no_config_works_without_site_packages(self):
  import subprocess,sys,tempfile
  from pathlib import Path
  with tempfile.TemporaryDirectory() as tmp:
   result=subprocess.run([sys.executable,'-S',str(Path(__file__).with_name('image_gc.py')),'gc','--config',str(Path(tmp)/'absent')],capture_output=True,text=True)
  self.assertEqual(result.returncode,0,result.stderr);self.assertIn('skipped',result.stdout)

class Automatic(unittest.TestCase):
 def test_rate_limits_credential_failures_and_manual_bypasses(self):
  import tempfile,json
  from pathlib import Path
  from image_gc import run
  from unittest.mock import Mock
  cfg={'image_arn':'owned','image_version':'8.0','image_gc':{'image_arn':'owned','rollback_version':'7.0'}}
  aws=Mock(side_effect=RuntimeError('Unable to locate credentials'))
  with tempfile.TemporaryDirectory() as tmp:
   path=Path(tmp)/'cfg';path.write_text(json.dumps(cfg))
   run(aws,path,automatic=True,emit=lambda _:None)
   run(aws,path,automatic=True,emit=lambda _:None)
   self.assertEqual(aws.call_count,1)
   run(aws,path,emit=lambda _:None);self.assertEqual(aws.call_count,2)
 def test_local_only_does_not_spawn(self):
  import tempfile
  from pathlib import Path
  from image_gc import schedule
  from unittest.mock import patch
  with tempfile.TemporaryDirectory() as tmp,patch('subprocess.Popen') as spawn:
   schedule(Path(tmp)/'missing');spawn.assert_not_called()
 def test_remote_spawns_nonblocking_maintenance(self):
  import tempfile,json,subprocess
  from pathlib import Path
  from image_gc import schedule
  from unittest.mock import patch
  with tempfile.TemporaryDirectory() as tmp,patch('subprocess.Popen') as spawn:
   path=Path(tmp)/'cfg';path.write_text(json.dumps({'image_gc':{'automatic':True}}))
   schedule(path)
   self.assertIn('--automatic',spawn.call_args.args[0])
   self.assertTrue(spawn.call_args.kwargs['start_new_session'])
   self.assertEqual(spawn.call_args.kwargs['stdin'],subprocess.DEVNULL)
 def test_concurrent_collection_skips_without_aws(self):
  import tempfile,json,fcntl
  from pathlib import Path
  from image_gc import run
  from unittest.mock import Mock
  with tempfile.TemporaryDirectory() as tmp:
   path=Path(tmp)/'cfg';path.write_text(json.dumps({'image_gc':{'automatic':True}}))
   with open(str(path)+'.gc.lock','w') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    aws=Mock();run(aws,path,automatic=True,emit=lambda _:None);aws.assert_not_called()
