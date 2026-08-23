import unittest

from checkout import Customer, LineItem, QuoteService


class CheckoutTests(unittest.TestCase):
    def setUp(self):
        self.items = [LineItem("book", 1000)]

    def test_regular_and_vip_prices(self):
        self.assertEqual(QuoteService().quote(Customer("r"), self.items), 1000)
        self.assertEqual(QuoteService().quote(Customer("v", "vip"), self.items), 800)

    def test_quantity_affects_price(self):
        items = [LineItem("book", 1000, quantity=2)]
        self.assertEqual(QuoteService().quote(Customer("r"), items), 2000)

    def test_vip_quote_after_regular_same_cart(self):
        service = QuoteService()
        self.assertEqual(service.quote(Customer("r"), self.items), 1000)
        self.assertEqual(service.quote(Customer("v", "vip"), self.items), 800)


if __name__ == "__main__":
    unittest.main()
