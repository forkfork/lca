import unittest

from orders import ConflictError, NotFoundError, Order, OrderAPI, OrderLine, OrderRepository, OrderService, OrderStatus
from orders.serialization import order_body, order_from_body


class OrderWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.repo = OrderRepository([Order("legacy", "alice", 900)])
        self.addCleanup(self.repo.close)
        self.service = OrderService(self.repo)
        self.service.inventory.replenish("book", 20)
        self.service.inventory.replenish("pen", 30)

    def place(self, name="new", customer="alice"):
        return self.service.place_order(name, customer, [OrderLine("book", 2, 700), OrderLine("pen", 3, 50)], shipping_cents=200)

    def test_place_authorizes_and_reserves(self):
        order = self.place()
        self.assertEqual(order.total_cents, 1750)
        self.assertEqual(order.version, 0)
        self.assertEqual(self.service.inventory.available("book"), 18)
        self.assertEqual(self.service.inventory.available("pen"), 27)
        self.assertEqual(self.service.payments.get("new").state, "authorized")
        self.assertEqual(self.service.payments.get("new").amount_cents, 1750)
        self.assertEqual([e.kind for e in self.repo.events_for("new")], ["placed"])
        self.assertEqual(self.service.outbox.pending()[0].topic, "order.placed")

    def test_ship_captures_and_commits(self):
        self.place()
        shipped = self.service.ship_order("new")
        self.assertEqual(shipped.status, OrderStatus.SHIPPED)
        self.assertEqual(shipped.version, 1)
        self.assertEqual(self.service.inventory.available("book"), 18)
        self.assertEqual(self.service.payments.get("new").state, "captured")
        self.assertTrue(all(r.state == "committed" for r in self.service.inventory.reservations_for("new")))
        self.assertEqual([e.kind for e in self.repo.events_for("new")], ["placed", "shipped"])
        with self.assertRaises(ConflictError):
            self.service.ship_order("new")

    def test_pay_then_ship_does_not_capture_twice(self):
        self.place()
        paid = self.service.pay_order("new")
        self.assertEqual(paid.status, OrderStatus.PAID)
        shipped = self.service.ship_order("new")
        self.assertEqual(shipped.version, 2)
        self.assertEqual([e.kind for e in self.repo.events_for("new")], ["placed", "paid", "shipped"])

    def test_legacy_shipping_has_no_payment_or_reservations(self):
        self.assertEqual(self.service.ship_order("legacy").status, OrderStatus.SHIPPED)
        self.assertIsNone(self.service.payments.get("legacy"))
        self.assertEqual(self.repo.events_for("legacy")[0].payload, {"units": 0})

    def test_customer_queries_sorted_and_isolated(self):
        self.place("zulu")
        self.place("alpha")
        self.place("foreign", "bob")
        self.assertEqual([o.order_id for o in self.service.list_orders("alice")], ["alpha", "legacy", "zulu"])
        self.assertEqual(self.service.list_orders("absent"), [])
        with self.assertRaises(NotFoundError):
            self.service.get_order("absent")

    def test_round_trip_retains_lines_and_currency(self):
        order = self.place()
        self.assertEqual(order_from_body(order_body(order)), order)
        self.assertEqual(self.repo.get("new"), order)

    def test_bad_line_items_do_not_create_orders(self):
        invalid = [[], [OrderLine("book", True, 10)], [OrderLine("book", 1, -1)],
                   [OrderLine("book", 0, 2)], [OrderLine("book", 1, 1), OrderLine("book", 1, 2)],
                   [{"sku":"book", "quantity":1}], "bad", None]
        for lines in invalid:
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                self.service.place_order("bad", "alice", lines)
            self.assertIsNone(self.repo.get("bad"))

    def test_bad_shipping_or_currency_rejected(self):
        for kwargs in ({"shipping_cents": True}, {"shipping_cents": -1}, {"currency": "BAD"}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.service.place_order("bad", "alice", [OrderLine("book", 1, 1)], **kwargs)
        self.assertIsNone(self.repo.get("bad"))

    def test_insufficient_stock_rolls_back_partial_reservations(self):
        with self.assertRaises(ConflictError):
            self.service.place_order("bad", "alice", [OrderLine("book", 1, 50), OrderLine("pen", 100, 1)])
        self.assertIsNone(self.repo.get("bad"))
        self.assertEqual(self.service.inventory.available("book"), 20)
        self.assertEqual(self.service.inventory.reservations_for("bad"), [])
        self.assertEqual(self.service.outbox.pending(), [])

    def test_duplicate_order_preserves_original(self):
        before = self.place()
        with self.assertRaises(ConflictError):
            self.place()
        self.assertEqual(self.repo.get("new"), before)
        self.assertEqual(self.service.inventory.available("book"), 18)

    def test_optimistic_update_rejects_stale_version(self):
        self.place()
        self.repo.set_status("new", OrderStatus.PAID, expected_version=0)
        with self.assertRaises(ConflictError):
            self.repo.set_status("new", OrderStatus.SHIPPED, expected_version=0)
        self.assertEqual(self.repo.get("new").version, 1)
