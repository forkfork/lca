import unittest

from runtime import timeout_for


class SettingsTests(unittest.TestCase):
    def test_known_timeouts(self):
        self.assertEqual(timeout_for("connect"), 10)
        self.assertIsInstance(timeout_for("request"), int)
        self.assertEqual(timeout_for("shutdown"), 15)

    def test_unknown_timeout(self):
        with self.assertRaisesRegex(ValueError, "unknown operation"):
            timeout_for("missing")


if __name__ == "__main__":
    unittest.main()
