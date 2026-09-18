"""Contract tests for the expanded fixture and independent grader."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
SCENARIO=ROOT/'evals/scenarios/multifile_order_cancellation'
spec=importlib.util.spec_from_file_location('order_reference',SCENARIO/'reference_solution.py')
reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)


def green_trajectory():
    return {'final':'Implemented and verified.', 'events':[
        {'name':'edit','args':{'path':'orders/service.py'},'result':{'content':'Edited','is_error':False}},
        {'name':'run','args':{'command':'python3 -m unittest discover -s tests -v'},
         'result':{'content':'Exit code: 0\nRan 31 tests in 0.2s\n\nOK\n','is_error':False}}]}


class OrderCancellationV2Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference_tmp=tempfile.TemporaryDirectory()
        cls.reference_root=Path(cls.reference_tmp.name)/'reference'
        shutil.copytree(SCENARIO/'fixture',cls.reference_root,ignore=shutil.ignore_patterns('__pycache__'))
        reference.install(cls.reference_root)

    @classmethod
    def tearDownClass(cls):cls.reference_tmp.cleanup()

    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.workspace=Path(self.tmp.name)/'workspace'
        shutil.copytree(self.reference_root,self.workspace,ignore=shutil.ignore_patterns('__pycache__'))

    def grade(self,trajectory=None):
        path=Path(self.tmp.name)/'trajectory.json';path.write_text(json.dumps(trajectory or green_trajectory()))
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
        p=subprocess.run([sys.executable,str(SCENARIO/'grade.py'),str(self.workspace),str(path)],env=env,capture_output=True,text=True,timeout=100)
        self.assertEqual(p.returncode,0,p.stderr)
        return json.loads(p.stdout)

    def test_reference_passes_all_gates(self):
        result=self.grade();self.assertTrue(result['passed'],result)
        self.assertGreaterEqual(len(result['evidence']['changed_files']),8)

    def test_unimplemented_fixture_fails_only_feature_tests_in_public_suite(self):
        p=subprocess.run([sys.executable,'-B','-m','unittest','discover','-s','tests','-v'],
                         cwd=SCENARIO/'fixture',capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0)
        self.assertIn('Ran 30 tests',p.stderr)
        self.assertIn('FAILED (failures=2)',p.stderr)
        self.assertNotIn('ERROR:',p.stderr)

    def test_known_bad_implementations_rejected(self):
        mutations=[
            ('lost_atomicity','orders/service.py','with self.repository.transaction():\n            receipt',
             'with __import__("contextlib").nullcontext():\n            receipt'),
            ('batch_partial_commit','orders/service.py','with self.repository.transaction():\n            return [self.cancel_order',
             'with __import__("contextlib").nullcontext():\n            return [self.cancel_order'),
            ('global_idempotency','orders/repository.py','WHERE order_id=? AND request_id=?",\n                                       (order_id, request_id)',
             'WHERE request_id=?",\n                                       (request_id,)'),
            ('live_snapshot_retry','orders/service.py','return order_from_body(json.loads(receipt["response_json"]))','return self.get_order(order_id)'),
            ('wrong_inventory_state','orders/inventory.py',"SET state='released'","SET state='committed'"),
            ('lost_hook','orders/repository.py','self.db.checkpoint("cancellation_saved")','pass'),
            ('lost_reason_identity','orders/service.py','if receipt["reason"] != reason:','if False:'),
            ('bool_version','orders/validation.py','if type(value) is not int or value < minimum:','if not isinstance(value,int) or value < minimum:'),
            ('cancelled_revenue','orders/reporting.py','if order.status is OrderStatus.CANCELLED:','if False:'),
            ('broken_cli','orders/cli.py','args.command == "cancel":','args.command == "cancel_broken":'),
        ]
        for name,file,old,new in mutations:
            with self.subTest(mutation=name):
                path=self.workspace/file;original=path.read_text();self.assertIn(old,original)
                path.write_text(original.replace(old,new,1))
                try:
                    result=self.grade();self.assertFalse(result['passed'],name)
                    self.assertFalse(result['hard_gates']['hidden_cancellation_contract'],name)
                finally:path.write_text(original)

    def test_grader_checks_source_not_stale_bytecode(self):
        import py_compile
        path=self.workspace/'orders/reporting.py'
        py_compile.compile(str(path),doraise=True,
                           invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)
        path.write_text(path.read_text().replace('if order.status is OrderStatus.CANCELLED:', 'if False:'))
        result=self.grade()
        self.assertFalse(result['hard_gates']['hidden_cancellation_contract'])

    def test_scope_and_migration_protection(self):
        for file in ('README.md','tests/test_orders.py','orders/migrations.py'):
            with self.subTest(file=file):
                path=self.workspace/file;original=path.read_text()
                changed=original+'\n# unauthorized\n' if not file.endswith('migrations.py') else original.replace('orders_customer ON orders(customer_id)','orders_customer ON orders(customer_id,order_id)')
                path.write_text(changed)
                try:
                    result=self.grade()
                    self.assertFalse(result['passed'])
                    gate='version_one_migration_preserved' if file.endswith('migrations.py') else 'scope_preserved'
                    self.assertFalse(result['hard_gates'][gate])
                finally:path.write_text(original)

    def test_verification_must_be_observed_after_last_edit(self):
        for trajectory in [dict(final='Done',events=[]),
                           dict(final='Done',events=list(reversed(green_trajectory()['events']))),
                           dict(final='Done',events=[green_trajectory()['events'][0],
                                {'name':'run','args':{'command':'echo tests passed'},'result':{'content':'OK','is_error':False}}])]:
            with self.subTest(trajectory=trajectory):
                result=self.grade(trajectory)
                self.assertTrue(result['evidence']['artifact_correct'])
                self.assertFalse(result['hard_gates']['observed_full_verification_after_final_edit'])

    def test_completed_durable_test_job_is_valid_evidence(self):
        trajectory=green_trajectory();trajectory['events']=trajectory['events'][:1]+[
            {'name':'job_start','args':{'command':'python3 -m unittest discover -s tests -v'},'result':{'job':{'id':'job_1'}}},
            {'name':'job_wait','args':{'id':'job_1'},'result':{'content':'status: exited\nexit_code: 0\nRan 31 tests in 0.2s\n\nOK\n'}}]
        self.assertTrue(self.grade(trajectory)['passed'])


if __name__=='__main__':unittest.main()
