import unittest

from payments import api_key, endpoint


class ConfigTests(unittest.TestCase):
    def test_missing_key_returns_none(self):
        self.assertIsNone(api_key({}))

    def test_endpoint_is_stable(self):
        self.assertEqual(endpoint(), "https://payments.example.test/v1")


if __name__ == "__main__":
    unittest.main()
