import contextlib
import argparse
import copy
import io
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import campaign


THEORY = {"id": "test", "minimum_runs_per_cell": 2,
          "scenarios": ["simple_prompt", "ambiguous_bug_investigation"],
          "variants": [{"id": "a", "model": "gpt-6-astra", "reasoning": "high"},
                       {"id": "b", "model": "gpt-5.6-sol", "reasoning": "high"}]}


class CampaignTests(unittest.TestCase):
    def test_screen_is_small_paired_and_never_a_promotion_matrix(self):
        theory = copy.deepcopy(THEORY)
        theory.update(study_kind="screen", minimum_runs_per_cell=1,
                      scenarios=["simple_prompt", "ambiguous_bug_investigation", "failure_recovery"])
        manifest = self.manifest(theory=theory, repetitions=1)
        self.assertEqual(len(manifest["cells"]), 6)
        self.assertEqual(manifest["decision_scope"], "screen_only")
        self.assertEqual(manifest, self.manifest(theory=theory, repetitions=1))
        self.assertTrue(all(c["stage"] == "screen" and c["repetition"] == 1 for c in manifest["cells"]))
        for i in range(0, 6, 2):
            pair = manifest["cells"][i:i+2]
            self.assertEqual(pair[0]["scenario"], pair[1]["scenario"])
            self.assertEqual({c["variant"]["id"] for c in pair}, {"a", "b"})
        with self.assertRaises(ValueError): self.manifest(theory=theory, repetitions=2)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); self.initialize(root, manifest)
            calls, state = self.execute_mocked(root, passed=False)
            self.assertEqual(calls, [0])
            self.assertIn("screen task failed", state["halted"])

    def test_task_suffix_is_frozen_and_audited(self):
        theory = copy.deepcopy(THEORY)
        theory["task_suffixes"] = {"ambiguous_bug_investigation": "\nDo not add files."}
        manifest = self.manifest(theory=theory)
        cell = next(c for c in manifest["cells"] if c["scenario"] == "ambiguous_bug_investigation")
        self.assertEqual(cell["task_suffix"], theory["task_suffixes"][cell["scenario"]])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.evidence(root, cell)
            expected = campaign.run.load_scenarios()[cell["scenario"]][1]["prompt"] + cell["task_suffix"]
            config = campaign.read(root / "run-config.json")
            config["scenario"] = {"prompt": expected}
            campaign.save(root / "run-config.json", config)
            request = campaign.read(root / "request-0001.json")
            request["messages"] = [{"role": "user", "text": expected + "\n"}]
            campaign.save(root / "request-0001.json", request)
            self.assertTrue(campaign.inspect_result(root, cell)["passed"])
            request["messages"] = []
            campaign.save(root / "request-0001.json", request)
            with self.assertRaisesRegex(ValueError, "task contract injection"):
                campaign.inspect_result(root, cell)
        theory["task_suffixes"] = {"unknown": "bad"}
        with self.assertRaises(ValueError):
            self.manifest(theory=theory)

    def test_graceful_stop_prevents_new_launches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.initialize(root, self.manifest())
            campaign.save(root / "stop-request.json", {"reason": "review needed"})
            calls, state = self.execute_mocked(root)
            self.assertEqual(calls, [])
            self.assertEqual(state["estimated_cost_usd"], 0)
            self.assertIn("between runs", state["halted"])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.initialize(root, self.manifest())
            calls, state = self.execute_mocked(root, stop_after_first=True)
            self.assertEqual(calls, [0])
            self.assertEqual(len(state["completed"]), 1)
            self.assertAlmostEqual(state["estimated_cost_usd"], 0.1)

    def manifest(self, **changes):
        values = dict(theory=copy.deepcopy(THEORY), smoke=THEORY["scenarios"], repetitions=2,
                      seed=12, max_runs=12, max_cost=5, max_seconds=60)
        values.update(changes)
        with patch.object(campaign, "source_digest", return_value="frozen"):
            return campaign.plan(**values)

    def initialize(self, root, manifest):
        campaign.save(root / "manifest.json", manifest)
        state = {"manifest_sha256": campaign.digest(manifest), "completed": {},
                 "elapsed_seconds": 0, "estimated_cost_usd": 0, "preflight_passed": True}
        campaign.save(root / "state.json", state)
        return state

    def evidence(self, root, cell, passed=True, cost=0.1):
        root.mkdir(exist_ok=True)
        variant = cell["variant"]
        campaign.save(root / "result.json", {"passed": passed, "metrics": {"estimated_total_api_cost_usd": cost}})
        campaign.save(root / "run-config.json", {"model": variant["model"], "reasoning": variant["reasoning"]})
        campaign.save(root / "trajectory.json", {"context_pilot": {"mode": "normal", "requests": 1, "responses": 1}, "usage": [{}]})
        campaign.save(root / "request-0001.json", {"model": variant["model"], "reasoning_effort": variant["reasoning"], "context_mode": "normal"})

    def test_matrix_is_seeded_smoke_first_and_pins_theory(self):
        first = self.manifest()
        self.assertEqual(first, self.manifest())
        self.assertEqual(len(first["cells"]), 12)
        self.assertEqual([c["stage"] for c in first["cells"][:4]], ["smoke"] * 4)
        self.assertEqual(len({c["id"] for c in first["cells"]}), 12)

    def test_unknown_interventions_and_bad_budgets_fail_closed(self):
        theory = copy.deepcopy(THEORY)
        theory["variants"][0]["unknown_switch"] = True
        for kwargs in ({"theory": theory}, {"max_cost": float("nan")}, {"max_seconds": 0},
                       {"repetitions": 1}, {"smoke": ["simple_prompt"]}):
            with self.assertRaises(ValueError):
                self.manifest(**kwargs)

    def test_missing_activation_or_usage_blocks_result(self):
        cell = self.manifest()["cells"][0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.evidence(root, cell)
            self.assertTrue(campaign.inspect_result(root, cell)["passed"])
            campaign.save(root / "request-0001.json", {"model": "wrong"})
            with self.assertRaisesRegex(ValueError, "activation"):
                campaign.inspect_result(root, cell)
            self.evidence(root, cell, cost=None)
            with self.assertRaisesRegex(ValueError, "cost"):
                campaign.inspect_result(root, cell)

    def test_experience_arm_audit_checks_injected_text_including_empty_control(self):
        import experience_context
        for mode in ("none", "raw", "ledger", "promoted"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                cell = self.manifest()["cells"][0]
                cell["variant"].update(experience_mode=mode, experience_bundle="test")
                self.evidence(root, cell)
                expected = {"mode": mode, "bundle_sha256": "frozen",
                            "text": "" if mode == "none" else experience_context.PREFIX + mode}
                campaign.save(root / "experience.json", expected)
                path = root / "request-0001.json"
                request = campaign.read(path)
                request["messages"] = [] if mode == "none" else [{"role": "user", "text": expected["text"]}]
                campaign.save(path, request)
                with patch.object(experience_context, "load", return_value=expected):
                    self.assertTrue(campaign.inspect_result(root, cell)["passed"])
                    request["messages"] = [{"role": "user", "text": experience_context.PREFIX + "wrong experience"}]
                    campaign.save(path, request)
                    with self.assertRaisesRegex(ValueError, "injection"):
                        campaign.inspect_result(root, cell)
    def test_source_drift_and_interrupted_run_refuse_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = self.initialize(root, self.manifest())
            with patch.object(campaign, "source_digest", return_value="changed"):
                with self.assertRaisesRegex(ValueError, "changed"):
                    campaign.execute(root, "unused")
            state["running"] = "cell-0000"
            campaign.save(root / "state.json", state)
            with patch.object(campaign, "source_digest", return_value="frozen"):
                with self.assertRaisesRegex(ValueError, "interrupted"):
                    campaign.execute(root, "unused")

    def execute_mocked(self, root, passed=True, protocol_error=False, stop_after_first=False):
        manifest = campaign.read(root / "manifest.json")
        calls = []
        owner = self
        class Process:
            def __init__(self, command, **kwargs):
                index = int(command[command.index("--index") + 1])
                calls.append(index)
                cell = manifest["cells"][index]
                owner.evidence(root / cell["id"], cell, passed=passed)
                if stop_after_first:
                    campaign.save(root / "stop-request.json", {"reason": "review needed"})
                if protocol_error:
                    trajectory = campaign.read(root / cell["id"] / "trajectory.json")
                    trajectory["error"] = "state protocol: missing state"
                    campaign.save(root / cell["id"] / "trajectory.json", trajectory)
            def wait(self, **kwargs):
                return 0
        with patch.object(campaign, "source_digest", return_value="frozen"), patch.object(campaign.subprocess, "Popen", Process), contextlib.redirect_stdout(io.StringIO()):
            campaign.execute(root, "unused")
        return calls, campaign.read(root / "state.json")

    def test_resume_never_repeats_completed_cells_and_budget_is_durable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.initialize(root, self.manifest(max_runs=2))
            calls, state = self.execute_mocked(root)
            self.assertEqual(calls, [0, 1])
            self.assertAlmostEqual(state["estimated_cost_usd"], 0.2)
            self.assertFalse(state["complete"])
            calls, resumed = self.execute_mocked(root)
            self.assertEqual(calls, [])
            self.assertEqual(resumed["completed"], state["completed"])

    def test_failed_smoke_is_counted_and_blocks_pilot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.initialize(root, self.manifest())
            calls, state = self.execute_mocked(root, passed=False)
            self.assertEqual(calls, [0])
            self.assertIn("smoke", state["halted"])
            self.assertAlmostEqual(state["estimated_cost_usd"], 0.1)

    def test_protocol_failure_is_not_promoted_by_passing_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.initialize(root, self.manifest())
            calls, state = self.execute_mocked(root, passed=True, protocol_error=True)
            self.assertEqual(calls, [0])
            self.assertIn("protocol", state["halted"])
            self.assertFalse(state["completed"]["cell-0000"]["passed"])
            self.assertAlmostEqual(state["estimated_cost_usd"], 0.1)

    def test_manifest_tampering_and_concurrent_controller_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = self.manifest()
            self.initialize(root, manifest)
            with (root / ".lock").open("a") as lock:
                campaign.fcntl.flock(lock, campaign.fcntl.LOCK_EX | campaign.fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    campaign.execute(root, "unused")
            manifest["max_runs"] += 1
            campaign.save(root / "manifest.json", manifest)
            with self.assertRaisesRegex(ValueError, "changed"):
                campaign.execute(root, "unused")

    def test_timeout_preserves_artifacts_and_partial_usage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scenario = root / "scenario"
            (scenario / "fixture").mkdir(parents=True)
            (scenario / "fixture/source.txt").write_text("original")
            (scenario / "grade.py").write_text("unused")
            output = root / "result"
            args = argparse.Namespace(model="gpt-6-astra", reasoning="high", seed=1,
                result_dir=output, credentials="unused", keep=True, judge="none")
            def timeout(*args, **kwargs):
                campaign.save(output / "trajectory.json", {"usage": [{"prompt_tokens": 100, "output_tokens": 10}], "events": []})
                raise subprocess.TimeoutExpired("fake", 1, output=b"partial stdout")
            with patch.object(campaign.run, "prepare_scenario_runtime", return_value=({}, None)), patch.object(campaign.run, "stop_scenario_runtime"), patch.object(campaign.run.subprocess, "run", side_effect=timeout):
                result = campaign.run.run_once(scenario, {"id": "test", "prompt": "fix", "grader": "grade.py"}, args, 1)
            self.assertFalse(result["passed"])
            self.assertEqual(result["failure_kind"], "timeout")
            self.assertTrue((output / "workspace/source.txt").exists())
            self.assertEqual((output / "timeout.stdout").read_text(), "partial stdout")
            self.assertGreater(result["metrics"]["estimated_api_cost_usd"], 0)

    def test_cost_threshold_stops_launches_and_complete_campaign_is_idempotent(self):
        for budget, count in ((0.05, 1), (5, 12)):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self.initialize(root, self.manifest(max_cost=budget))
                calls, state = self.execute_mocked(root)
                self.assertEqual(len(calls), count)
                self.assertEqual(state["complete"], count == 12)
                calls, _ = self.execute_mocked(root)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
