import copy
import importlib.util
from pathlib import Path
import unittest

SUPPORT = Path(__file__).resolve().parents[1] / "scenarios/auth_api_strict/grader_support.py"
spec = importlib.util.spec_from_file_location("auth_strict_support", SUPPORT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AuthStrictTests(unittest.TestCase):
    def test_every_required_behavior_is_a_hard_gate(self):
        good = {"passed": True, "score": 100, "hard_gates": {},
                "evidence": {"checks": {key: True for key in module.REQUIRED_CHECKS}, "forbidden_artifacts": []}}
        self.assertTrue(module.strict_grade(good, True, True)["passed"])
        for key in module.REQUIRED_CHECKS:
            for missing in (False, True):
                bad = copy.deepcopy(good)
                if missing: del bad["evidence"]["checks"][key]
                else: bad["evidence"]["checks"][key] = False
                result = module.strict_grade(bad, True, True)
                self.assertFalse(result["passed"], key)
                self.assertTrue(result["legacy_passed"])
        self.assertFalse(module.strict_grade(good, False, True)["passed"])
        self.assertFalse(module.strict_grade(good, True, False)["passed"])
        good["evidence"]["forbidden_artifacts"] = ["Dockerfile"]
        self.assertFalse(module.strict_grade(good, True, True)["passed"])
