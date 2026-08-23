import unittest

from service import configured_port


class PortTests(unittest.TestCase):
    def test_configured_and_ephemeral_ports(self):
        self.assertEqual(configured_port({"APP_PORT": "9123"}), 9123)
        self.assertEqual(configured_port({"APP_PORT": "0"}), 0)

    def test_invalid_port_is_rejected(self):
        with self.assertRaises(ValueError):
            configured_port({"APP_PORT": "70000"})


if __name__ == "__main__":
    unittest.main()
