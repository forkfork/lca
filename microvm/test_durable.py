import json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from durable import archive_dead
class RecoveryTests(unittest.TestCase):
 def test_dead_handoff_preserves_newer_local_session_and_files(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);checkpoint=root/'checkpoint';checkpoint.write_text(json.dumps({'id':'old','pending_inputs':['do not replay']}))
   marker=root/'.lca-handoff.json';marker.write_text('{}')
   session={'id':'new','messages':[{'role':'user','text':'current'}]}
   (root/'.lca-session.json').write_text(json.dumps(session));(root/'file').write_text('current work')
   rec={'checkpoint':str(checkpoint),'session_id':'old'}
   archive=archive_dead(marker,rec,{'state':'TERMINATED'})
   self.assertEqual(json.loads((root/'.lca-session.json').read_text()),session)
   self.assertEqual((root/'file').read_text(),'current work');self.assertFalse(marker.exists())
   self.assertTrue((archive/'.lca-handoff.json').exists())
 def test_old_session_does_not_replay_uncertain_queue(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);checkpoint=root/'checkpoint';checkpoint.write_text(json.dumps({'id':'old','pending_inputs':['unsafe']}))
   marker=root/'.lca-handoff.json';marker.write_text('{}')
   archive_dead(marker,{'checkpoint':str(checkpoint),'session_id':'old'},{'state':'TERMINATED'})
   self.assertEqual(json.loads((root/'.lca-session.json').read_text())['pending_inputs'],[])
 def test_recovery_refuses_running_vm(self):
  from handoff import recover
  with patch('handoff.aws',return_value={'state':'RUNNING'}):
   with self.assertRaisesRegex(AssertionError,'not terminated'):recover({},Path('unused'),{'phase':'remote','vm':{'microvmId':'test'}})

class StoredRecoveryTests(unittest.TestCase):
 def test_initial_recovery_preserves_workspace_and_holds_attempted_input(self):
  import subprocess
  from durable import initial,restore
  from workspace import snapshot
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);project=root/'project';project.mkdir()
   subprocess.run(['git','init','-q',str(project)],check=True)
   subprocess.run(['git','-C',str(project),'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m','baseline'],check=True)
   (project/'untracked').write_text('saved content')
   artifact=root/'artifact';snapshot(project,artifact)
   data={'id':'test','cwd':str(project),'messages':[],'credentials_path':'private-local-path','pending_inputs':['!first','!second']}
   cp=root/'session.json';cp.write_text(json.dumps(data));rec={'checkpoint':str(cp)};objects={}
   def put(cfg,store,key,data):objects[key]=data
   def get(cfg,store,key):return objects[key]
   def s3(cfg,op,*args):return {'Contents':[{'Key':rec['durable']['prefix']+'/'+key} for key in objects]}
   with patch('retention.ensure'),patch('durable.put',side_effect=put),patch('durable.get',side_effect=get),patch('durable.s3',side_effect=s3):
    rec['durable']=initial({'checkpoint_bucket':'test-bucket'},rec,data,artifact)
    self.assertNotIn('credentials_path',json.loads(objects['latest.json'])['session'])
    objects['attempts/initial-1.json']=b'{}'
    dest,uncertain=restore({},rec,root/'restored')
    self.assertEqual((dest/'project/untracked').read_text(),'saved content')
    saved=json.loads((dest/'project/.lca-session.json').read_text())
    self.assertEqual(saved['pending_inputs'],['!second']);self.assertEqual(uncertain[0]['id'],'initial-1')
    objects['initial.tgz']=b'corrupted'
    with self.assertRaisesRegex(ValueError,'checksum'):restore({},rec,root/'bad')
