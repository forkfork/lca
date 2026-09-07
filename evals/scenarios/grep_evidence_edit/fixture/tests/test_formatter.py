import unittest

from diagnostics import format_status


class FormatterTests(unittest.TestCase):
    def test_timeout_uses_current_marker(self):
        self.assertEqual(format_status("timeout", " slow "), "request_timeout:slow")

    def test_other_markers_are_unchanged(self):
        self.assertEqual(format_status("ok", "done"), "request_ok:done")
        self.assertEqual(format_status("denied", "no"), "request_denied:no")


if __name__ == "__main__":
    unittest.main()
