import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'evals'))
from file_tools import audit, normalize, ALLOWED
from verification_evidence import verified_after_mutations


class FileToolsTests(unittest.TestCase):
    def test_real_lua_interface_and_filesystem_audit(self):
        for mode in ('native', 'shell'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                workspace = directory / 'workspace'
                workspace.mkdir()
                (workspace / 'sample.txt').write_text('before')
                script = '''local root, dir, cwd, mode = ...
local json = require('agent.util.json')
local registry = require('agent.tool_registry')
local baseline = require('agent.system_prompt').build({cwd=cwd,model='gpt-6-astra'})
local session = {cwd=cwd,tool_scope='local_only',get_system_prompt=function() return baseline end}
local observe = dofile(root .. '/evals/file_tools.lua').apply(mode,session,root,dir)
local function save(name,x) local f=assert(io.open(dir..'/'..name,'w')); f:write(json.encode(x)); f:close() end
local f=assert(io.open(cwd..'/sample.txt','w')); f:write('after'); f:close()
local events = {{name='run',result={is_error=false,content='done'}}}; observe(events[1])
events[2] = {name='run',result={is_error=false,content='no change'}}; observe(events[2])
assert(os.remove(cwd..'/sample.txt'))
events[3] = {name='run',result={is_error=true,content='removed then failed'}}; observe(events[3])
save('trajectory.json',{events=events})
save('request-0001.json',{system_prompt=session.system_prompt})
save('provider-request-0001.json',{instructions=session.system_prompt,tools=registry.native_tools()})
if mode=='shell' then assert(not pcall(registry.execute,'read',{path='sample.txt'},{cwd=cwd})) end
'''
                env = dict(os.environ)
                env['LUA_PATH'] = str(ROOT / 'lua/?.lua') + ';' + str(ROOT / 'lua/?/init.lua') + ';;'
                completed = subprocess.run(['lua', '-', str(ROOT), str(directory), str(workspace), mode],
                                           input=script, text=True, capture_output=True, env=env, timeout=30)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                trajectory = json.loads((directory / 'trajectory.json').read_text())
                requests = [directory / 'request-0001.json']
                audit(directory, mode, requests, trajectory)
                bad = copy.deepcopy(trajectory)
                bad['events'][0]['file_changes'] = []
                with self.assertRaisesRegex(ValueError, 'boundary'):
                    audit(directory, mode, requests, bad)
                payload = json.loads((directory / 'provider-request-0001.json').read_text())
                payload['tools'] = []
                (directory / 'provider-request-0001.json').write_text(json.dumps(payload))
                with self.assertRaisesRegex(ValueError, 'activation'):
                    audit(directory, mode, requests, trajectory)

    def test_observed_mutations_require_later_verification_even_after_failed_command(self):
        green = {'name':'run','args':{'command':'python3 -m unittest'},
                 'result':{'is_error':False,'content':'Ran 2 tests in 0.01s\n\nOK\n'}}
        mutation = dict(green, file_changes=['sample.py'], file_boundary=1)
        raw = {'events':[mutation]}
        self.assertFalse(verified_after_mutations(normalize(raw)['events']))
        self.assertEqual(len(raw['events']), 1)
        self.assertTrue(verified_after_mutations(normalize({'events':[mutation, green]})['events']))
        mutation['result'] = {'is_error':True,'content':'partial write then failure'}
        self.assertFalse(verified_after_mutations(normalize({'events':[green, mutation]})['events']))


if __name__ == '__main__':
    unittest.main()
