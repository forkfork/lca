import unittest

from shipping import quote


class QuoteTests(unittest.TestCase):
    def test_existing_standard_and_expedited_prices(self):
        self.assertEqual(quote(1), 620)
        self.assertEqual(quote(1001), 740)
        self.assertEqual(quote(1, True), 1320)

    def test_zero_weight_is_free(self):
        self.assertEqual(quote(0), 0)
        self.assertEqual(quote(0, True), 0)

    def test_negative_weight_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "negative"):
            quote(-1)

    def test_fragile_surcharge_composes(self):
        self.assertEqual(quote(1, fragile=True), 870)
        self.assertEqual(quote(1, expedited=True, fragile=True), 1570)
        self.assertEqual(quote(0, fragile=True), 0)


if __name__ == "__main__":
    unittest.main()
