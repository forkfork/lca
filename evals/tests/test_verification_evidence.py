import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verification_evidence import successful_unittest, verified_after_mutations


class VerificationEvidenceTests(unittest.TestCase):
    def event(self, content="Ran 3 tests in 0.001s\n\nOK\n", error=False, command="python3 -m unittest discover -s tests -v"):
        return {"name": "run", "args": {"command": command}, "result": {"content": content, "is_error": error}}

    def test_requires_completed_test_summary_and_relevant_command(self):
        self.assertTrue(successful_unittest(self.event()))
        self.assertTrue(successful_unittest(self.event("Ran 3 tests\nOK", command="check")))
        self.assertFalse(successful_unittest(self.event("OK")))
        self.assertFalse(successful_unittest(self.event("Ran 0 tests\nOK\n")))
        self.assertFalse(successful_unittest(self.event(command="git diff --check")))
        self.assertFalse(successful_unittest({"phase": "start", "name": "run", "args": {"command": "check"}}))
        self.assertFalse(successful_unittest(self.event("Ran 3 tests\nFAILED (failures=1)\n")))

    def test_last_summary_and_compound_failure_boundary(self):
        self.assertTrue(successful_unittest(self.event("Ran 3 tests\nFAILED (failures=1)\nRan 3 tests\nOK\n")))
        self.assertFalse(successful_unittest(self.event("Ran 3 tests\nOK\nRan 3 tests\nFAILED (failures=1)\n")))
        green_git = "Ran 3 tests\nOK\nwarning: Not a git repository.\n"
        self.assertTrue(successful_unittest(self.event(green_git, True, "check && git diff")))
        self.assertFalse(successful_unittest(self.event(green_git + "Traceback (most recent call last):\nAssertionError", True, "check && git diff")))
        self.assertFalse(successful_unittest(self.event("Ran 3 tests\nOK\nprobe failed", True)))

    def test_mutations_invalidate_earlier_verification(self):
        mutation = {"name": "edit", "result": {"content": "edited", "is_error": False}}
        self.assertFalse(verified_after_mutations([self.event(), mutation]))
        self.assertTrue(verified_after_mutations([mutation, self.event()]))
