from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals"))

import run  # noqa: E402


class EvalMetricsTests(unittest.TestCase):
    def test_astra_long_context_pricing_is_per_request(self):
        for prompts, expected in [([272_000, 272_000], 5.45), ([272_001], 5.44752)]:
            trajectory = {"events": [], "usage": [
                {"prompt_tokens": prompt, "output_tokens": 100}
                for prompt in prompts
            ]}
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "trajectory.json"
                path.write_text(json.dumps(trajectory))
                metrics = run.trajectory_metrics(path, model="gpt-6-astra")
            self.assertAlmostEqual(metrics["estimated_api_cost_usd"], expected)

    def test_cache_adjusted_input_cost_separates_reads_writes_and_uncached_tokens(self):
        trajectory = {
            "tool_calls": 0,
            "llm_calls": 1,
            "elapsed_ms": 1,
            "events": [],
            "model_activities": [
                {"type": "web_search", "phase": "searching", "id": "ws-1"},
                {"type": "web_search", "phase": "completed", "id": "ws-1"},
                {"type": "web_search", "phase": "searching", "id": "ws-2"},
            ],
            "usage": [{
                "prompt_tokens": 10_000,
                "cached_tokens": 4_000,
                "cache_write_tokens": 1_000,
                "output_tokens": 200,
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trajectory.json"
            path.write_text(json.dumps(trajectory))
            metrics = run.trajectory_metrics(path, model="gpt-5.6-sol")

        self.assertEqual(metrics["uncached_prompt_tokens"], 5_000)
        self.assertEqual(metrics["hosted_web_searches"], 2)
        self.assertAlmostEqual(metrics["estimated_input_cost_usd"], 0.0266)
        self.assertAlmostEqual(metrics["estimated_api_cost_usd"], 0.0306)

    def test_delegate_usage_and_total_cost_are_counted_from_tool_events(self):
        trajectory = {
            "tool_calls": 1,
            "llm_calls": 2,
            "elapsed_ms": 1,
            "usage": [{"prompt_tokens": 1_000, "cached_tokens": 0, "output_tokens": 100}],
            "events": [{
                "name": "delegate_readonly",
                "dag": {"node_id": "analysis", "depends_on": [], "wave": 1},
                "readonly_fork_join": {"active": True, "leader": True},
                "result": {"delegate": {"model": "gpt-5.6-terra", "usage": {
                    "prompt_tokens": 500, "cached_tokens": 100, "output_tokens": 50,
                }}},
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trajectory.json"
            path.write_text(json.dumps(trajectory))
            metrics = run.trajectory_metrics(path, model="gpt-5.6-sol")

        self.assertEqual(metrics["delegate_calls"], 1)
        self.assertEqual(metrics["delegate_prompt_tokens"], 500)
        self.assertEqual(metrics["delegate_cached_tokens"], 100)
        self.assertEqual(metrics["delegate_output_tokens"], 50)
        self.assertEqual(metrics["dag_nodes"], 1)
        self.assertEqual(metrics["readonly_fork_join_calls"], 1)
        self.assertEqual(metrics["readonly_fork_join_batches"], 1)
        self.assertEqual(metrics["dag_waves"], 1)
        self.assertEqual(metrics["dag_skipped_nodes"], 0)
        self.assertAlmostEqual(metrics["estimated_delegate_cost_usd"], 0.00142)
        self.assertAlmostEqual(
            metrics["estimated_total_api_cost_usd"],
            metrics["estimated_api_cost_usd"] + 0.00142,
        )

    def test_delegate_cost_uses_recorded_child_model(self):
        trajectory = {
            "events": [{
                "name": "delegate_readonly",
                "result": {"delegate": {
                    "model": "gpt-5.6-luna",
                    "usage": {"prompt_tokens": 1000, "cached_tokens": 0, "output_tokens": 1000},
                }},
            }],
            "usage": [],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trajectory.json"
            path.write_text(json.dumps(trajectory))
            metrics = run.trajectory_metrics(path, model="gpt-5.6-sol")
        self.assertAlmostEqual(metrics["estimated_delegate_cost_usd"], 0.0014)


if __name__ == "__main__":
    unittest.main()
