import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from exploration import Ledger, sha
import experience_context


def evidence(content):
    return [{"source": "external-evaluator.json", "content": content, "sha256": sha(content)}]


def observation():
    return {"id": "o1", "task_id": "discovery", "family": "repeated-analysis",
            "question": "What determines analysis time?", "hypothesis": "secret hypothesis",
            "intervention": "cache parsed AST per unchanged file",
            "observation": {"before_ms": 840, "after_ms": 310},
            "judgment": "secret conclusion", "confidence": 0.85,
            "evidence": evidence({"before_ms": 840, "after_ms": 310})}


def candidate():
    return {"id": "c1", "observations": ["o1"], "family": "repeated-analysis",
            "lesson": "Cache parsed ASTs", "condition": "Repeated analysis of unchanged files",
            "metric": "elapsed_ms", "validation_tasks": [f"v{i}" for i in range(5)],
            "evaluation_tasks": ["ambiguous_bug_investigation"],
            "rule": {"direction": "lower", "minimum_median_gain": 0.1, "maximum_regression": 0.05}}


def validation(index, gain, passed=True):
    proof = {"candidate": "c1", "task_id": f"v{index}", "family": "repeated-analysis",
             "metric": "elapsed_ms", "before": 100, "after": 100 * (1 - gain),
             "control_passed": True, "treatment_passed": passed,
             "fixture_sha256": "fixture-hash", "grader_sha256": "grader-hash",
             "model": "test-model", "reasoning": "high", "control_run": f"a{index}", "treatment_run": f"b{index}"}
    return {"candidate": "c1", "task_id": f"v{index}", "family": "repeated-analysis", "evidence": evidence(proof)}


class ExplorationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ledger = Ledger(Path(self.temp.name) / "ledger")
        self.ledger.append("observation", observation())
        self.ledger.append("candidate", candidate())

    def fill(self, gains=(.21, .18, .02, -.04, .16), fail=None):
        for i, gain in enumerate(gains):
            self.ledger.append("validation", validation(i, gain, passed=i != fail))

    def raw(self):
        return [{"task_id": task, "trajectory": {"text": "synthetic test fixture"}} for task in ["discovery", *candidate()["validation_tasks"]]]

    def test_confidence_cannot_promote_without_other_tasks(self):
        self.assertFalse(self.ledger.assess("c1")["eligible"])
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.ledger.append("promotion", {"candidate": "c1"})
        self.assertEqual(len(self.ledger.events()), 2)

    def test_five_mixed_effects_promote_conditional_lesson(self):
        self.fill()
        event = self.ledger.append("promotion", {"candidate": "c1", "lesson": "Ignore scope"})
        self.assertEqual(event["payload"]["condition"], candidate()["condition"])
        self.assertEqual(event["payload"]["lesson"], candidate()["lesson"])
        self.assertAlmostEqual(event["payload"]["validation"]["median_gain"], .16)
        with self.assertRaisesRegex(ValueError, "already promoted"):
            self.ledger.append("promotion", {"candidate": "c1"})

    def test_regressions_and_incorrect_results_block_promotion(self):
        self.fill(fail=4)
        self.assertEqual(self.ledger.assess("c1")["reason"], "paired correctness gate failed")

    def test_large_regression_blocks_even_with_positive_median(self):
        self.fill((.3, .3, .3, .3, -.2))
        self.assertFalse(self.ledger.assess("c1")["eligible"])

    def test_duplicates_and_discovery_reuse_are_rejected(self):
        self.ledger.append("validation", validation(0, .2))
        with self.assertRaisesRegex(ValueError, "duplicate validation"):
            self.ledger.append("validation", validation(0, .3))
        body = candidate()
        body["id"] = "c2"
        body["validation_tasks"][0] = "discovery"
        with self.assertRaisesRegex(ValueError, "disjoint"):
            self.ledger.append("candidate", body)

    def test_run_ids_cannot_be_relabelled_as_new_validation_tasks(self):
        self.ledger.append("validation", validation(0, .2))
        body = validation(1, .2)
        proof = body["evidence"][0]["content"]
        proof["control_run"] = "a0"
        body["evidence"] = evidence(proof)
        with self.assertRaisesRegex(ValueError, "reused"):
            self.ledger.append("validation", body)

    def test_wrong_metric_and_unregistered_tasks_rejected(self):
        body = validation(0, .2)
        proof = body["evidence"][0]["content"]
        proof["metric"] = "different_metric"
        body["evidence"] = evidence(proof)
        with self.assertRaisesRegex(ValueError, "metric mismatch"):
            self.ledger.append("validation", body)
        body = validation(0, .2)
        body["task_id"] = "ambiguous_bug_investigation"
        with self.assertRaisesRegex(ValueError, "cohort"):
            self.ledger.append("validation", body)

    def test_evidence_and_ledger_tampering_detected(self):
        body = validation(0, .2)
        body["evidence"][0]["content"]["after"] = 1
        with self.assertRaisesRegex(ValueError, "hash"):
            self.ledger.append("validation", body)
        path = self.ledger.directory / "000000.json"
        item = json.loads(path.read_text())
        item["payload"]["judgment"] = "tampered"
        path.write_text(json.dumps(item))
        with self.assertRaisesRegex(ValueError, "changed"):
            self.ledger.events()

    def test_views_exclude_conclusions_and_do_not_auto_promote(self):
        bundle = self.ledger.views(self.raw())
        self.assertEqual(bundle["views"]["none"], "")
        self.assertEqual(bundle["views"]["promoted"], "[]")
        self.assertIn("secret conclusion", bundle["views"]["ledger"])
        for forbidden in ("secret", "confidence", "judgment", "lesson", "external-evaluator"):
            self.assertNotIn(forbidden, bundle["views"]["blind"])
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.ledger.views([{"task_id": "wrong", "trajectory": "x"}])

    def test_bundle_rejects_empty_promoted_arm_and_task_leakage(self):
        root = Path(self.temp.name)
        directory = root / "evals/experience_corpora"
        directory.mkdir(parents=True)
        path = directory / "test.json"
        path.write_text(json.dumps(self.ledger.views(self.raw())))
        variant = {"experience_bundle": "evals/experience_corpora/test.json", "experience_mode": "promoted"}
        with patch.object(experience_context, "ROOT", root):
            with self.assertRaisesRegex(ValueError, "empty control"):
                experience_context.load(variant, "ambiguous_bug_investigation")
            with self.assertRaisesRegex(ValueError, "leakage"):
                experience_context.load(variant, "v0")
            self.fill()
            self.ledger.append("promotion", {"candidate": "c1"})
            path.write_text(json.dumps(self.ledger.views(self.raw())))
            self.assertIn("Cache parsed ASTs", experience_context.load(variant, "ambiguous_bug_investigation")["text"])
            variant["experience_mode"] = "none"
            self.assertEqual(experience_context.load(variant, "simple_prompt")["text"], "")


if __name__ == "__main__":
    unittest.main()
