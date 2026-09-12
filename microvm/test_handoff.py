import importlib.util,json,os,subprocess,tempfile,unittest
from pathlib import Path
from workspace import snapshot
from handoff import recover,atomic
class SnapshotTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)/'project';self.root.mkdir()
  self.git('init','-q');self.git('config','user.name','Test');self.git('config','user.email','test@example.invalid')
  (self.root/'file').write_text('base\n');(self.root/'.gitignore').write_text('.env\n.lca-*\n');self.git('add','.');self.git('commit','-qm','base')
 def git(self,*args):return subprocess.check_output(['git','-C',str(self.root),*args])
 def test_dirty_staging_and_untracked(self):
  (self.root/'file').write_text('staged\n');self.git('add','file');(self.root/'file').write_text('working\n')
  (self.root/'new file').write_text('new');(self.root/'script').write_text('true');(self.root/'script').chmod(0o755)
  (self.root/'link').symlink_to('file');(self.root/'.env').write_text('SECRET=not-for-transfer')
  dest=Path(self.temp.name)/'artifact';m=snapshot(self.root,dest)
  self.assertNotIn('.env',m);self.assertEqual(m['link'],{'link':'file'});self.assertTrue(m['script']['executable'])
  clone=Path(self.temp.name)/'clone';subprocess.run(['git','clone','-q',str(dest/'repo.bundle'),str(clone)],check=True)
  subprocess.run(['git','-C',str(clone),'apply','--cached',str(dest/'index.patch')],check=True)
  import tarfile
  with tarfile.open(dest/'files.tar') as t:t.extractall(clone,filter='data')
  self.assertEqual(subprocess.check_output(['git','-C',str(clone),'show',':file']),b'staged\n')
  self.assertEqual((clone/'file').read_text(),'working\n');self.assertEqual((clone/'new file').read_text(),'new')
 def test_external_symlink_rejected(self):
  (self.root/'escape').symlink_to('/etc/passwd')
  with self.assertRaisesRegex(ValueError,'external symlink'):snapshot(self.root,Path(self.temp.name)/'artifact')
 def test_tracked_credential_rejected(self):
  (self.root/'credentials.json').write_text('{}');self.git('add','credentials.json')
  with self.assertRaisesRegex(ValueError,'credential-like'):snapshot(self.root,Path(self.temp.name)/'artifact')
 def test_local_recovery_and_remote_replay_refusal(self):
  cp=Path(self.temp.name)/'checkpoint.json';atomic(cp,{'id':'same','pending_inputs':['one','two']})
  marker=self.root/'.lca-handoff.json';rec={'phase':'prepared','checkpoint':str(cp)};atomic(marker,rec)
  recover({},marker,rec)
  self.assertEqual(json.loads((self.root/'.lca-queue.json').read_text())['inputs'],['one','two'])
  with self.assertRaises(AssertionError):recover({},marker,{'phase':'remote'})
if __name__=='__main__':unittest.main()
