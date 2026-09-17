import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from job_results import grade, audit, executable

COMMAND = (Path(__file__).resolve().parents[1] / 'scenarios/job_receipt/verify-command.txt').read_text()

class JobResultTests(unittest.TestCase):
    def fixture(self, root):
        (root / 'verify.py').write_bytes((Path(__file__).resolve().parents[1] / 'scenarios/job_receipt/fixture/verify.py').read_bytes())
        (root / 'summarize.py').write_text("def total(rows):\n return sum(r['amount'] for r in rows if r['status']=='ok')\n")
        (root / '.receipt').write_text(hashlib.sha256((root / 'summarize.py').read_bytes()).hexdigest())
        job = root / '.lca/jobs/job_1'; job.mkdir(parents=True)
        out = job / 'stdout.log'; out.write_text('VERIFIED\n')
        (job / 'job.json').write_text(json.dumps({'id':'job_1','command':COMMAND,'status':'exited','exit_code':0,'stdout':str(out)}))
        return {'events':[{'name':'job_wait','args':{'id':'job_1'},'result':{'content':'status: exited\nexit_code: 0\nVERIFIED'}}]}

    def test_only_padding_comment_may_vary(self):
        changed=COMMAND.replace('verification-context ', 'verification-context verification-context ', 1)
        self.assertEqual(executable(COMMAND),executable(changed))
        self.assertNotEqual(executable(COMMAND),executable(COMMAND.replace('verify.py','wrong.py')))

    def test_good_artifact_and_independent_bad_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp); trajectory=self.fixture(p)
            self.assertTrue(grade(p,trajectory)['passed'])
            (p/'summarize.py').write_text("def total(rows):\n return sum(r['amount'] for r in rows)\n")
            (p/'.receipt').write_text(hashlib.sha256((p/'summarize.py').read_bytes()).hexdigest())
            self.assertFalse(grade(p,trajectory)['hard_gates']['artifact_correct'])

    def test_copied_evidence_can_be_regraded(self):
        import shutil
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); original=root/'original'; original.mkdir()
            trajectory=self.fixture(original)
            copy=root/'copy'; shutil.copytree(original,copy); shutil.rmtree(original)
            self.assertTrue(grade(copy,trajectory)['passed'])

    def test_requires_final_receipt_and_observed_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp); trajectory=self.fixture(p)
            self.assertFalse(grade(p,{'events':[]})['passed'])
            (p/'.receipt').write_text('stale')
            self.assertFalse(grade(p,trajectory)['passed'])

    def test_rejects_scope_and_unverified_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp); trajectory=self.fixture(p)
            (p/'extra.py').write_text('')
            self.assertFalse(grade(p,trajectory)['passed'])
            (p/'extra.py').unlink()
            path=p/'.lca/jobs/job_1/job.json'; job=json.loads(path.read_text());job['command']='true';path.write_text(json.dumps(job))
            self.assertFalse(grade(p,trajectory)['passed'])

    def test_audit_checks_serialized_response_not_just_arm_label(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp); request=p/'request-0001.json'; request.write_text(json.dumps({'system_prompt':'same'}))
            content='id: job_1\nstatus: running\ncommand: short...'
            trajectory={'job_results':'compact','events':[{'name':'job_start','args':{'command':COMMAND},'result':{'content':content,'job':{'command':COMMAND}}}]}
            payload=p/'provider-request-0001.json'; payload.write_text(json.dumps({'instructions':'same','tools':[],'input':[{'output':'wrapper\n'+content}]}))
            audit(p,'compact',[request],trajectory)
            payload.write_text(json.dumps({'instructions':'same','tools':[],'input':[]}))
            with self.assertRaisesRegex(ValueError,'missing from outgoing'):
                audit(p,'compact',[request],trajectory)
            trajectory['events'][0]['result']['content'] += COMMAND
            with self.assertRaisesRegex(ValueError,'format mismatch'):
                audit(p,'compact',[request],trajectory)

if __name__=='__main__': unittest.main()
