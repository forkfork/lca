import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'evals'))
from discovery_tools import audit


class DiscoveryToolsTests(unittest.TestCase):
    def test_real_lua_preserves_native_reads_edits_and_exact_request_audit(self):
        for mode in ('native', 'shell'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                workspace = directory / 'workspace'
                workspace.mkdir()
                script = '''local root, dir, cwd, mode = ...
local json = require('agent.util.json')
local registry = require('agent.tool_registry')
local prompt = require('agent.system_prompt').build({cwd=cwd,model='gpt-6-astra'})
local session = {cwd=cwd,tool_scope='local_only',get_system_prompt=function() return prompt end}
dofile(root .. '/evals/discovery_tools.lua').apply(mode,session,root,dir)
local function save(name,x) local f=assert(io.open(dir..'/'..name,'w')); f:write(json.encode(x)); f:close() end
save('request-0001.json',{system_prompt=session.system_prompt})
save('provider-request-0001.json',{instructions=session.system_prompt,tools=registry.native_tools()})
if mode=='shell' then
 for _, name in ipairs({'ls','find','grep'}) do assert(not pcall(registry.execute,name,{},{})) end
end
'''
                env = dict(os.environ)
                env['LUA_PATH'] = str(ROOT / 'lua/?.lua') + ';' + str(ROOT / 'lua/?/init.lua') + ';;'
                result = subprocess.run(['lua', '-', str(ROOT), str(directory), str(workspace), mode],
                                        input=script, text=True, capture_output=True, env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                requests = [directory / 'request-0001.json']
                audit(directory, mode, requests, {'events': []})
                body_path = directory / 'provider-request-0001.json'
                body = json.loads(body_path.read_text())
                bad = copy.deepcopy(body)
                next(t for t in bad['tools'] if t['name']=='edit')['description'] = 'changed'
                body_path.write_text(json.dumps(bad))
                with self.assertRaisesRegex(ValueError, 'activation'):
                    audit(directory, mode, requests, {'events': []})

    def test_registration_and_invalid_modes(self):
        import campaign
        theory = json.loads((ROOT / 'evals/theories/astra_discovery_tools_screen.json').read_text())
        def plan(value):
            return campaign.plan(value, value['scenarios'], 1, 910, 4, 1.5, 360)
        self.assertEqual(len(plan(theory)['cells']), 4)
        for changed in ({'discovery_tools':'typo'}, {'tool_scope':'all'}, {'system_prompt_profile':'current'}):
            bad = copy.deepcopy(theory)
            bad['variants'][1].update(changed)
            with self.assertRaisesRegex(ValueError, 'discovery interface'):
                plan(bad)

    def test_full_bug_grader_accepts_reference_and_rejects_shortcuts(self):
        scenario = ROOT / 'evals/scenarios/ambiguous_bug_investigation'
        for case in ('good', 'unimplemented', 'customer-id-key', 'scope', 'no-verification'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                workspace = Path(tmp) / 'workspace'
                shutil.copytree(scenario / 'fixture', workspace)
                events = [{'name':'read','args':{'path':str(p.relative_to(workspace))},
                           'result':{'is_error':False,'content':p.read_text()}}
                          for p in sorted((workspace / 'checkout').glob('*.py'))]
                command = [sys.executable, '-m', 'unittest', 'discover', '-s', 'tests', '-v']
                def verify():
                    p = subprocess.run(command, cwd=workspace, text=True, capture_output=True, timeout=30)
                    return {'name':'run','args':{'command':'python3 -m unittest discover -s tests -v'},
                            'result':{'is_error':bool(p.returncode),'content':p.stdout+p.stderr}}
                failed = verify()
                self.assertTrue(failed['result']['is_error'])
                events.append(failed)
                source = workspace / 'checkout/service.py'
                if case != 'unimplemented':
                    key = 'customer.customer_id' if case == 'customer-id-key' else 'discount_percent(customer)'
                    body = source.read_text()
                    self.assertEqual(body.count('key = self.cache.key(items)'), 1)
                    source.write_text(body.replace('key = self.cache.key(items)', f'key = ({key}, self.cache.key(items))'))
                    events.append({'name':'edit','args':{'path':'checkout/service.py'},
                                   'result':{'is_error':False,'content':'reference repair'}})
                if case == 'scope': (workspace / 'README.md').write_text('unrelated overwrite')
                if case != 'no-verification': events.append(verify())
                trajectory = Path(tmp) / 'trajectory.json'
                trajectory.write_text(json.dumps({'events':events,'final':'Repaired cache key.'}))
                p = subprocess.run([sys.executable,str(scenario / 'grade.py'),str(workspace),str(trajectory)],
                                   capture_output=True,text=True,timeout=30)
                self.assertEqual(p.returncode, 0, p.stderr)
                grade = json.loads(p.stdout)
                self.assertEqual(grade['passed'], case == 'good', grade)


if __name__ == '__main__':
    unittest.main()
