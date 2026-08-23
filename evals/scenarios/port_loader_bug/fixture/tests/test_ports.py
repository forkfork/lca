import unittest

from service import configured_port


class PortTests(unittest.TestCase):
    def test_missing_port_uses_default(self):
        self.assertEqual(configured_port({}), 8000)

    def test_invalid_port_is_rejected(self):
        with self.assertRaises(ValueError):
            configured_port({"APP_PORT": "70000"})


if __name__ == "__main__":
    unittest.main()
