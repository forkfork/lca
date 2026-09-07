import copy
from pathlib import Path
import sys
import json
import subprocess
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from analyze_cache_prefix import compare
class CachePrefixTests(unittest.TestCase):
    def test_append_only_drop_and_real_prefix_changes(self):
        a={'model':'gpt-6-astra','tools':[{'name':'read','parameters':{'a':1,'b':2}}],
           'input':[{'role':'user','content':'task'}]}
        b=copy.deepcopy(a);b['input'].append({'role':'assistant','content':'reply'})
        before,after={'cached_tokens':9600},{'cached_tokens':3712}
        r=compare(a,b,before,after)
        self.assertTrue(r['unchanged_prefix_cache_drop'])
        self.assertEqual(r['cache_drop_tokens'],5888)
        for field in ['model','tools','input']:
            bad=copy.deepcopy(b);bad[field]='changed'
            self.assertFalse(compare(a,bad,before,after)['unchanged_prefix_cache_drop'])
        self.assertFalse(compare(a,b,after,before)['unchanged_prefix_cache_drop'])
    def test_object_order_change_is_distinct_from_value_change(self):
        a={'tools':[{'name':'read','description':'Read'}],'input':[]}
        b={'tools':[{'description':'Read','name':'read'}],'input':[]}
        r=compare(a,b,{'cached_tokens':2},{'cached_tokens':1})
        self.assertTrue(r['stable_prefix'])
        self.assertFalse(r['recorded_object_order_stable'])

    def test_capture_preserves_serialized_object_order(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as tmp:
            script = "\n".join([
                'package.path="./lua/?.lua;./lua/?/init.lua;"..package.path',
                'require("luarocks.loader")',
                'local session={messages={}}',
                'local p=dofile("evals/state_context.lua").new("normal",session,' + json.dumps(tmp) + ')',
                'local request={messages={},model="gpt-6-astra"}',
                'p.on_request(request)',
                'request.on_request_body([[{ "z": 1, "a": { "y": 2, "b": 3 } }]])',
            ])
            subprocess.run(['lua','-'],input=script,text=True,cwd=root,check=True,capture_output=True)
            self.assertEqual((Path(tmp)/'provider-request-0001.json').read_text(),
                             '{ "z": 1, "a": { "y": 2, "b": 3 } }\n')
