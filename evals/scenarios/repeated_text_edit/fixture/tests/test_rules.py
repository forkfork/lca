import unittest

from pipelines import PIPELINES


class PipelineRulesTests(unittest.TestCase):
    def test_all_pipelines_have_expected_step_order(self):
        for pipeline in PIPELINES.values():
            self.assertEqual(
                [step.name for step in pipeline.steps],
                ["validate", "transform", "publish"],
            )

    def test_default_transform_policy(self):
        for name in ("ingest", "archive"):
            transform = PIPELINES[name].steps[1]
            self.assertEqual(transform.timeout_seconds, 60)
            self.assertEqual(transform.retries, 2)

    def test_export_transform_policy_is_valid(self):
        transform = PIPELINES["export"].steps[1]
        self.assertGreater(transform.timeout_seconds, 0)
        self.assertGreaterEqual(transform.retries, 0)


if __name__ == "__main__":
    unittest.main()
