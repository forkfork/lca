"""Contract checks for immutable, supplied cancellation tests."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCENARIO = ROOT / 'evals/scenarios/multifile_order_cancellation_fixed_tests'
spec = importlib.util.spec_from_file_location('fixed_order_reference', ROOT / 'evals/scenarios/multifile_order_cancellation/reference_solution.py')
reference = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reference)


class FixedOrderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.workspace = Path(self.tmp.name) / 'workspace'
        shutil.copytree(SCENARIO / 'fixture', self.workspace, ignore=shutil.ignore_patterns('__pycache__'))
        reference.install(self.workspace)
        (self.workspace / 'tests/test_cancellation_added.py').unlink()

    def grade(self, tool='edit', after_test=False):
        edit = {'name':tool, 'args':{'path':'orders/service.py'}, 'result':{'content':'Updated','is_error':False}}
        events = [edit, {'name':'run','args':{'command':'python3 -m unittest discover -s tests -v'},
                        'result':{'content':'Exit code: 0\nRan 52 tests in 0.2s\nOK\n','is_error':False}}]
        if after_test:
            events.append(edit)
        trajectory = Path(self.tmp.name) / 'trajectory.json'
        trajectory.write_text(json.dumps({'events':events}))
        result = subprocess.run([sys.executable, '-B', str(SCENARIO / 'grade.py'), str(self.workspace), str(trajectory)],
                                capture_output=True, text=True, timeout=100,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_reference_passes_identical_supplied_tests_with_both_edit_interfaces(self):
        for tool in ('edit', 'apply_patch'):
            with self.subTest(tool=tool):
                result = self.grade(tool)
                self.assertTrue(result['passed'], result)
                self.assertIn('Ran 52 tests', result['evidence']['public_test_output'])
                self.assertEqual(result['evidence']['added_files'], [])

    def test_test_addition_modification_and_deletion_fail_scope(self):
        path = self.workspace / 'tests/test_cancellation_contract.py'
        original = path.read_bytes()
        for mode in ('add', 'modify', 'delete'):
            with self.subTest(mode=mode):
                added = self.workspace / 'tests/test_extra.py'
                if mode == 'add': added.write_text('# forbidden extra test\n')
                elif mode == 'modify': path.write_bytes(original + b'\n# changed\n')
                else: path.unlink()
                result = self.grade()
                self.assertFalse(result['hard_gates']['scope_preserved'])
                self.assertFalse(result['hard_gates']['supplied_tests_unchanged'])
                path.write_bytes(original)
                added.unlink(missing_ok=True)

    def test_broken_atomicity_and_noop_fail_behavior(self):
        path = self.workspace / 'orders/service.py'
        original = path.read_text()
        old = 'with self.repository.transaction():\n            receipt'
        self.assertIn(old, original)
        path.write_text(original.replace(old, 'with __import__("contextlib").nullcontext():\n            receipt', 1))
        result = self.grade()
        self.assertFalse(result['hard_gates']['public_regressions_and_examples'])
        self.assertFalse(result['hard_gates']['hidden_cancellation_contract'])
        shutil.rmtree(self.workspace / 'orders')
        shutil.copytree(SCENARIO / 'fixture/orders', self.workspace / 'orders')
        self.assertFalse(self.grade()['passed'])

    def test_patch_after_test_invalidates_verification(self):
        result = self.grade('apply_patch', after_test=True)
        self.assertFalse(result['hard_gates']['observed_full_verification_after_final_edit'])
