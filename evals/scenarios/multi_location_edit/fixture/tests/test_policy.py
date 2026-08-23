import unittest

from runtime.policy import (
    canonical_region,
    endpoint_url,
    feature_enabled,
    request_headers,
    request_timeout,
    retry_delays,
    service_port,
)


class RuntimePolicyTests(unittest.TestCase):
    def test_requested_policy_changes(self):
        self.assertEqual(request_timeout(), 45)
        self.assertEqual(canonical_region(" us-east "), "US-EAST-1")
        self.assertEqual(endpoint_url("api.example.test"), "https://api.example.test:443")

    def test_existing_policy_behavior_is_preserved(self):
        self.assertEqual(request_timeout(12), 12)
        self.assertEqual(retry_delays("request"), (2, 5, 10))
        self.assertTrue(feature_enabled("audit_events"))
        self.assertEqual(request_headers()["x-client-mode"], "bounded")
        self.assertEqual(service_port("metrics"), 9090)


if __name__ == "__main__":
    unittest.main()
