import unittest
from invoice import total

class InvoiceTests(unittest.TestCase):
    def test_tax(self):
        self.assertEqual(total(10000, 10), 11000)
    def test_rounding(self):
        self.assertEqual(total(999, 7), 1068)
    def test_zero(self):
        self.assertEqual(total(1200, 0), 1200)
