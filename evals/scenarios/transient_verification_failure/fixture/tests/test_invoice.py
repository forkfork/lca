import unittest

from billing import renewal_total


class RenewalTotalTests(unittest.TestCase):
    def test_account_credit_is_applied(self):
        self.assertEqual(renewal_total(1100, 100), 1000)

    def test_credit_cannot_make_total_negative(self):
        self.assertEqual(renewal_total(100, 300), 0)

    def test_negative_amount_is_rejected(self):
        with self.assertRaises(ValueError):
            renewal_total(-1, 0)


if __name__ == "__main__":
    unittest.main()
