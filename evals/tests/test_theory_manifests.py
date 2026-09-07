from __future__ import annotations

import sys
import copy
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals"))

import run  # noqa: E402


class TheoryManifestTests(unittest.TestCase):
    def test_screen_requires_exactly_two_arms_and_small_single_pass(self):
        theory = copy.deepcopy(run.load_theories()["astra_workflow_fast_screen"])
        scenarios = run.load_scenarios()
        run.validate_theories({theory["id"]: theory}, scenarios)
        for key, value in (("minimum_runs_per_cell", 2), ("variants", theory["variants"][:1]),
                           ("scenarios", ["failure_recovery", "multifile_order_cancellation"]),
                           ("scenarios", ["simple_prompt", "failure_recovery", "multifile_order_cancellation", "existing_codebase_edit"])):
            bad = copy.deepcopy(theory); bad[key] = value
            with self.assertRaises(ValueError): run.validate_theories({bad["id"]: bad}, scenarios)

    def test_calibration_is_explicit_and_cannot_hide_a_comparison(self):
        theory = copy.deepcopy(run.load_theories()["astra_long_build_calibration"])
        scenarios = run.load_scenarios()
        run.validate_theories({theory["id"]: theory}, scenarios)
        theory.pop("study_kind")
        with self.assertRaises(ValueError): run.validate_theories({theory["id"]: theory}, scenarios)
        theory["study_kind"] = "calibration"
        theory["variants"].append(dict(theory["variants"][0], id="another"))
        with self.assertRaises(ValueError): run.validate_theories({theory["id"]: theory}, scenarios)

    def test_all_registered_theories_are_complete_and_resolvable(self):
        scenarios = run.load_scenarios()
        theories = run.load_theories()
        run.validate_theories(theories, scenarios)


if __name__ == "__main__":
    unittest.main()
