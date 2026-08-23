import unittest
from decimal import Decimal

from checkout import DiscountRule, LineItem, parse_discount_rule, quote


class CheckoutTests(unittest.TestCase):
    def test_quote_without_discount(self):
        result = quote([LineItem("book", 1299, 2)], tax_rate=Decimal("10"))
        self.assertEqual(result.subtotal_cents, 2598)
        self.assertEqual(result.discount_cents, 0)
        self.assertEqual(result.tax_cents, 260)
        self.assertEqual(result.total_cents, 2858)

    def test_discount_only_applies_to_eligible_items(self):
        result = quote(
            [
                LineItem("book", 1000),
                LineItem("gift-card", 500, discountable=False),
            ],
            DiscountRule("SAVE10", Decimal("10")),
        )
        self.assertEqual(result.discount_cents, 100)
        self.assertEqual(result.total_cents, 1400)

    def test_percentage_uses_half_up_rounding(self):
        result = quote(
            [LineItem("cable", 105)],
            DiscountRule("HALF", Decimal("50")),
        )
        self.assertEqual(result.discount_cents, 53)

    def test_parse_discount_rule(self):
        rule = parse_discount_rule({"code": " SAVE15 ", "percent": "15"})
        self.assertEqual(rule, DiscountRule("SAVE15", Decimal("15")))

    def test_invalid_percentage_is_rejected(self):
        for value in ("not-a-number", -1, 101):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    parse_discount_rule({"code": "BAD", "percent": value})


if __name__ == "__main__":
    unittest.main()
