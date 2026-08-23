import unittest

from payments import api_key, endpoint


class ConfigTests(unittest.TestCase):
    def test_api_key_uses_documented_environment_name(self):
        self.assertEqual(api_key({"PAYMENTS_API_KEY": "secret-value"}), "secret-value")
        self.assertIsNone(api_key({"PAYMENT_API_KEY": "wrong-name"}))

    def test_endpoint_is_stable(self):
        self.assertEqual(endpoint(), "https://payments.example.test/v1")


if __name__ == "__main__":
    unittest.main()
