import json, subprocess, tarfile
from pathlib import Path
from unittest.mock import patch
from test_handoff import SnapshotTests
from workspace import snapshot
from reconcile import plan, apply, Conflict
from handoff import duration, go_local, atomic

class ReturnTests(SnapshotTests):
 def copies(self):
  artifact=Path(self.temp.name)/'artifact';snapshot(self.root,artifact)
  remote=Path(self.temp.name)/'remote'
  subprocess.run(['git','clone','-q',str(artifact/'repo.bundle'),str(remote)],check=True)
  if (artifact/'index.patch').stat().st_size:subprocess.run(['git','-C',str(remote),'apply','--cached',str(artifact/'index.patch')],check=True)
  manifest=json.loads((artifact/'manifest.json').read_text())
  for name,item in manifest['files'].items():
   if item.get('deleted'):(remote/name).unlink(missing_ok=True)
  with tarfile.open(artifact/'files.tar') as f:f.extractall(remote,filter='data')
  return artifact,remote,Path(self.temp.name)/'plan.json'
 def test_return_preserves_staging_and_local_edits(self):
  (self.root/'file').write_text('staged\n');self.git('add','file');(self.root/'file').write_text('working\n')
  artifact,remote,out=self.copies()
  (remote/'file').write_text('remote\n');(remote/'remote-new').write_text('remote new\n')
  (self.root/'local-new').write_text('local new\n')
  transaction=plan(self.root,remote,artifact,out);apply(self.root,transaction);apply(self.root,transaction)
  self.assertEqual((self.root/'file').read_text(),'remote\n');self.assertEqual(self.git('show',':file'),b'staged\n')
  self.assertEqual((self.root/'local-new').read_text(),'local new\n');self.assertEqual((self.root/'remote-new').read_text(),'remote new\n')
 def test_disjoint_edits_merge(self):
  (self.root/'file').write_text('one\ntwo\nthree\nfour\nfive\nsix\nseven\n')
  artifact,remote,out=self.copies()
  (self.root/'file').write_text((self.root/'file').read_text().replace('one','LOCAL'))
  (remote/'file').write_text((remote/'file').read_text().replace('seven','REMOTE'))
  apply(self.root,plan(self.root,remote,artifact,out))
  self.assertIn('LOCAL', (self.root/'file').read_text());self.assertIn('REMOTE',(self.root/'file').read_text())
 def test_conflict_changes_nothing(self):
  artifact,remote,out=self.copies();(self.root/'file').write_text('local\n');(remote/'file').write_text('remote\n');(remote/'aaa').write_text('new\n')
  before=(self.root/'.git/index').read_bytes()
  with self.assertRaises(Conflict):plan(self.root,remote,artifact,out)
  self.assertFalse((self.root/'aaa').exists());self.assertEqual((self.root/'file').read_text(),'local\n');self.assertEqual((self.root/'.git/index').read_bytes(),before)
 def test_changed_after_plan_refused(self):
  artifact,remote,out=self.copies();(remote/'file').write_text('remote\n')
  transaction=plan(self.root,remote,artifact,out);(self.root/'file').write_text('concurrent\n')
  with self.assertRaises(Conflict):apply(self.root,transaction)
  self.assertEqual((self.root/'file').read_text(),'concurrent\n');self.assertFalse((self.root/'.git/index.lock').exists())
 def test_delete_binary_mode_and_staged_add(self):
  artifact,remote,out=self.copies();(remote/'file').unlink();(remote/'binary').write_bytes(b'\0test');(remote/'binary').chmod(0o755)
  subprocess.run(['git','-C',str(remote),'add','-A'],check=True)
  apply(self.root,plan(self.root,remote,artifact,out))
  self.assertFalse((self.root/'file').exists());self.assertEqual(self.git('show',':binary'),b'\0test');self.assertTrue((self.root/'binary').stat().st_mode & 0o111)
 def test_staged_deletion_survives_snapshot_and_return(self):
  self.git('rm','-q','file')
  artifact,remote,out=self.copies()
  self.assertFalse((remote/'file').exists())
  apply(self.root,plan(self.root,remote,artifact,out))
  self.assertFalse((self.root/'file').exists());self.assertNotIn(b'file',self.git('ls-files'))
 def test_duration(self):
  self.assertEqual(duration({}),28800)
  for invalid in [86400,0,True,'28800']:
   with self.assertRaises(ValueError):duration({'maximum_duration':invalid})
 def test_return_terminates_before_unlock_and_preserves_queue(self):
  artifact,remote,out=self.copies();(remote/'file').write_text('remote\n')
  returned=remote.parent/'returned';returned.mkdir();remote.rename(returned/'project')
  saved={'id':'same','credentials_path':'/local/creds','pending_inputs':['next'],'messages':[]}
  atomic(returned/'state.json',{'phase':'stopped'});atomic(returned/'project/.lca-session.json',saved)
  checkpoint=remote.parent/'checkpoint.json';atomic(checkpoint,saved)
  marker=self.root/'.lca-handoff.json';rec={'phase':'collected','checkpoint':str(checkpoint),'artifact':str(artifact),'collected':str(returned),'vm':{'microvmId':'fake'}};atomic(marker,rec)
  def aws(cfg,command,*args):
   self.assertTrue(marker.exists());self.assertEqual(json.loads(marker.read_text())['phase'],'local_ready')
   self.assertEqual((self.root/'file').read_text(),'remote\n')
   return {'state':'TERMINATED'}
  with patch('handoff.aws',side_effect=aws):go_local({},marker,rec,resume=False)
  self.assertFalse(marker.exists());self.assertEqual(json.loads((self.root/'.lca-queue.json').read_text())['inputs'],['next'])
