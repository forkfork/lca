from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals"))

import run  # noqa: E402


class TheoryManifestTests(unittest.TestCase):
    def test_all_registered_theories_are_complete_and_resolvable(self):
        scenarios = run.load_scenarios()
        theories = run.load_theories()
        run.validate_theories(theories, scenarios)


if __name__ == "__main__":
    unittest.main()
