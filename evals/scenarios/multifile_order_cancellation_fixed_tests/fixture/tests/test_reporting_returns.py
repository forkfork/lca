import unittest
from orders import ConflictError, NotFoundError, Order, OrderLine, OrderRepository, OrderService, OrderStatus
from orders.reporting import Reports
from orders.returns import Returns


class ReportingAndReturnsTests(unittest.TestCase):
    def setUp(self):
        self.repo = OrderRepository([Order("pending", "a", 100), Order("paid", "a", 200, OrderStatus.PAID),
                                     Order("shipped", "a", 300, OrderStatus.SHIPPED),
                                     Order("usd", "a", 400, currency="USD"), Order("other", "b", 999)])
        self.addCleanup(self.repo.close)
        self.reports = Reports(self.repo)
        self.returns = Returns(self.repo)

    def test_summary_currency_buckets_and_customer_isolation(self):
        summary = self.reports.customer_summary("a")
        self.assertEqual(summary["order_count"], 4)
        self.assertEqual(summary["status_counts"], {"pending":2, "paid":1, "shipped":1})
        self.assertEqual(summary["totals"], {"AUD":{"open_cents":300, "shipped_cents":300},
                                              "USD":{"open_cents":400, "shipped_cents":0}})
        self.assertEqual(self.reports.customer_summary("absent")["totals"], {})

    def test_returns_idempotent_and_bounded(self):
        first = self.returns.refund("r1", "shipped", 100, "damaged")
        self.assertEqual(self.returns.refund("r1", "shipped", 100, "damaged"), first)
        self.returns.refund("r2", "shipped", 200, "damaged")
        with self.assertRaises(ConflictError):
            self.returns.refund("r3", "shipped", 1, "damaged")
        with self.assertRaises(ConflictError):
            self.returns.refund("r1", "shipped", 101, "damaged")
        self.assertEqual(len(self.repo.events_for("shipped")), 2)
        self.assertEqual(self.repo.get("shipped").status, OrderStatus.SHIPPED)

    def test_nonshipped_returns_rejected(self):
        for name in ("pending", "paid"):
            with self.assertRaises(ConflictError):
                self.returns.refund("r", name, 1, "reason")
        with self.assertRaises(NotFoundError):
            self.returns.refund("r", "missing", 1, "reason")
        for amount in (True, -1, 0, "10"):
            with self.assertRaises(ValueError):
                self.returns.refund("r", "shipped", amount, "reason")

    def test_inventory_summary_distinguishes_physical_and_available(self):
        service = OrderService(self.repo)
        service.inventory.replenish("sku", 5)
        service.place_order("stock-order", "a", [OrderLine("sku", 2, 10)])
        self.assertEqual(self.reports.inventory_summary(), [{"sku":"sku", "on_hand":5, "available":3}])
