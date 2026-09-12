import json,shutil,subprocess,tempfile,unittest,zipfile
from pathlib import Path
class InstalledPackageTests(unittest.TestCase):
 def test_deployed_lua_sources_included_without_checkout(self):
  with tempfile.TemporaryDirectory() as tmp:
   tree=Path(tmp)/'tree';root=tree/'lib/luarocks/rocks-5.5/lca/dev-1'
   micro=root/'microvm';micro.mkdir(parents=True)
   shutil.copyfile(Path(__file__).with_name('package.py'),micro/'package.py')
   (root/'lca-dev-1.rockspec').write_text('package="lca"; build={modules={["agent.session"]="lua/agent/session.lua"}}')
   deployed=tree/'share/lua/5.5/agent';deployed.mkdir(parents=True);(deployed/'session.lua').write_text('return {}')
   for name in ['c/crypto.c','bin/lca','scripts/auth.lua','scripts/login.lua','microvm/bootstrap.lua','microvm/smoke.sh','microvm/worker.lua','microvm/lifecycle.lua','microvm/publish.lua','microvm/headless.lua','microvm/checkpoint.lua','microvm/fixture/test','microvm/Dockerfile']:
    p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture')
   out=Path(tmp)/'context'
   subprocess.run(['python3',str(micro/'package.py'),str(out)],check=True,capture_output=True,text=True,cwd=tmp)
   self.assertEqual((out/'lua/agent/session.lua').read_text(),'return {}')
   self.assertIsNone(json.loads((out/'source-manifest.json').read_text())['git_revision'])
   with zipfile.ZipFile(str(out)+'.zip') as archive:self.assertIn('lua/agent/session.lua',archive.namelist())
