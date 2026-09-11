import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from obligation_discrimination import grade, hashes, audit
from run import trajectory_metrics
ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'evals/scenarios/obligation_ready/fixture'

class DiscriminationTests(unittest.TestCase):
    def test_grader_distinguishes_missing_valid_repeated_and_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp); w = p / 'workspace'; shutil.copytree(FIXTURE, w)
            def evaluate(scenario, outcomes):
                (p / 'obligation-screen.json').write_text(json.dumps({'scenario': scenario}))
                rows = []
                for i, (exit_code, snapshot) in enumerate(outcomes):
                    rows += [{'id': str(i), 'phase': 'start', 'hashes': snapshot},
                             {'id': str(i), 'phase': 'finish', 'hashes': snapshot, 'exit_code': exit_code}]
                (p / 'check-invocations.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
                return grade(w,p,FIXTURE)
            h = hashes(w)
            self.assertFalse(evaluate('pending', [(1,h)])['passed'])
            self.assertTrue(evaluate('pending', [(1,h),(0,h)])['passed'])
            self.assertTrue(evaluate('ready', [(1,h),(0,h)])['passed'])
            repeated = evaluate('ready', [(1,h),(0,h),(0,h)])
            self.assertFalse(repeated['passed'])
            self.assertTrue(repeated['hard_gates']['verified_final_files'])
            (w/'billing/invoice.py').write_text((w/'billing/invoice.py').read_text()+'\n# subsequent edit\n')
            stale = evaluate('ready', [(1,h),(0,h)])
            self.assertFalse(stale['hard_gates']['verified_final_files'])
            self.assertFalse(stale['hard_gates']['scope_preserved'])
            (w/'billing/invoice.py').write_text('def renewal_total(*args): return 999\n')
            self.assertFalse(evaluate('pending', [(1,h),(0,hashes(w))])['hard_gates']['artifact_correct'])

    def test_actual_view_audit_rejects_leak_and_missing_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            seed = {'arm':'receipts','scenario':'simple_prompt','events':[], 'view':''}
            (p/'obligation-screen.json').write_text(json.dumps(seed))
            request = p/'request-0001.json'
            request.write_text(json.dumps({'messages':[{'text':'17*23'}]}))
            payload = p/'provider-request-0001.json'
            payload.write_text(json.dumps({'input':[]}))
            audit(p,'receipts',[request],{'obligation_screen':seed})
            request.write_text(json.dumps({'messages':[{'text':'<operational-state>leak'}]}))
            with self.assertRaisesRegex(AssertionError,'wrong view'):
                audit(p,'receipts',[request],{'obligation_screen':seed})
            payload.unlink()
            with self.assertRaisesRegex(AssertionError,'missing actual'):
                audit(p,'receipts',[request],{'obligation_screen':seed})

    def test_checkpoint_cost_is_included(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'trajectory.json'
            p.write_text(json.dumps({'usage':[{'prompt_tokens':100,'output_tokens':10}],
                'checkpoint_usage':[{'prompt_tokens':200,'output_tokens':20}], 'llm_calls':1}))
            m = trajectory_metrics(p, model='gpt-6-astra')
            self.assertEqual(m['prompt_tokens'],300)
            self.assertEqual(m['llm_calls'],2)
            self.assertAlmostEqual(m['estimated_total_api_cost_usd'], .0045)

if __name__ == '__main__': unittest.main()
