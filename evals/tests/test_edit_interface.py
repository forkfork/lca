import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from edit_interface import audit, SUBSTITUTIONS, PATCH_SPEC


class EditInterfaceTests(unittest.TestCase):
    def test_wire_activation_and_negative_contracts(self):
        for arm in ('tagged', 'openai_patch_fixed_tests'):
            with self.subTest(arm=arm), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                def save(name, value):
                    (root / name).write_text(json.dumps(value))
                baseline_tools = [{'type': 'function', 'name': 'edit'}, {'type': 'function', 'name': 'read'}]
                baseline_prompt = '\n'.join(old for old, _ in SUBSTITUTIONS)
                prompt = baseline_prompt if arm == 'tagged' else '\n'.join(new for _, new in SUBSTITUTIONS)
                tools = baseline_tools if arm == 'tagged' else [PATCH_SPEC, baseline_tools[1]]
                save('edit-interface.json', dict(profile=arm, baseline_prompt=baseline_prompt,
                    effective_prompt=prompt, baseline_tools=baseline_tools, effective_tools=tools))
                request = {'system_prompt': prompt}
                save('request-0001.json', request)
                operation = {'type': 'update_file', 'path': 'orders/service.py', 'diff': '@@\n-old\n+new'}
                items = [] if arm == 'tagged' else [
                    {'type': 'function_call', 'name': 'apply_patch', 'call_id': 'one', 'arguments': json.dumps(operation)},
                    {'type': 'function_call_output', 'call_id': 'one', 'output': 'done'}]
                body = {'tools': tools, 'instructions': prompt, 'input': items}
                save('provider-request-0001.json', body)
                save('run-config.json', {'scenario': {'id': 'multifile_order_cancellation_fixed_tests'}})
                event = {'name': 'edit' if arm == 'tagged' else 'apply_patch', 'call_id': 'one',
                         'args': operation, 'result': {'is_error': False, 'content':'done'}}
                trajectory = {'edit_tool_profile': arm, 'tool_scope': 'local_only', 'events': [event]}
                requests = [root / 'request-0001.json']
                audit(root, arm, requests, trajectory)
                for field, bad_value in [('tools', []), ('instructions', 'drift')]:
                    bad = copy.deepcopy(body); bad[field] = bad_value
                    save('provider-request-0001.json', bad)
                    with self.assertRaises(ValueError): audit(root, arm, requests, trajectory)
                save('provider-request-0001.json', body)
                for events in ([], [dict(event, name='write')],
                               [event, {'name':'write','args':{'path':'orders/service.py'},'result':{}}],
                               [event, {'name':'run','args':{'command':'python3 rewrite.py'},'result':{}}]):
                    bad = dict(trajectory, events=events)
                    with self.assertRaises(ValueError): audit(root, arm, requests, bad)
                if arm == 'openai_patch_fixed_tests':
                    for new_items in (items[:1], [items[0], dict(items[1],output='wrong')],
                                      [dict(items[0],arguments='{}'),items[1]]):
                        save('provider-request-0001.json', dict(body,input=new_items))
                        with self.assertRaises(ValueError): audit(root, arm, requests, trajectory)

    def test_campaign_accepts_only_supported_edit_profiles(self):
        from test_campaign import CampaignTests, THEORY
        for arm in ('apply_patch', 'tagged', 'openai_patch_fixed_tests', 'exact', 'typo'):
            theory = copy.deepcopy(THEORY)
            theory['variants'][0]['edit_tool_profile'] = arm
            if arm == 'apply_patch':
                CampaignTests().manifest(theory=theory)
            else:
                with self.assertRaises(ValueError): CampaignTests().manifest(theory=theory)
