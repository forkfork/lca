import unittest

from ledger import Transaction, summarize


class SummaryTests(unittest.TestCase):
    def test_only_posted_transactions_are_summarized(self):
        transactions = [
            Transaction(1200),
            Transaction(300, "pending"),
            Transaction(-400, "reversed"),
        ]
        self.assertEqual(summarize(transactions), (1200, 1))

    def test_generator_input_is_supported(self):
        transactions = (Transaction(amount) for amount in (100, 250))
        self.assertEqual(summarize(transactions), (350, 2))


if __name__ == "__main__":
    unittest.main()
