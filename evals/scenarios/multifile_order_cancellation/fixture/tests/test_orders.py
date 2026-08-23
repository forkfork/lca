import unittest

from orders import (
    ConflictError,
    Order,
    OrderAPI,
    OrderRepository,
    OrderService,
    OrderStatus,
)


class OrderWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.repository = OrderRepository([
            Order("pending-1", "customer-a", 1250),
            Order("shipped-1", "customer-a", 800, OrderStatus.SHIPPED),
            Order("other-1", "customer-b", 500),
        ])
        self.service = OrderService(self.repository)
        self.api = OrderAPI(self.service)

    def test_existing_queries_are_preserved(self):
        order = self.service.get_order("pending-1")
        self.assertEqual(order.total_cents, 1250)
        self.assertEqual(
            {item.order_id for item in self.service.list_orders("customer-a")},
            {"pending-1", "shipped-1"},
        )
        response = self.api.handle("GET", "/orders/pending-1")
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body["status"], "pending")

    def test_existing_shipping_records_one_event(self):
        shipped = self.service.ship_order("pending-1")
        self.assertEqual(shipped.status, OrderStatus.SHIPPED)
        self.assertEqual(
            [event.kind for event in self.repository.events_for("pending-1")],
            ["shipped"],
        )
        with self.assertRaises(ConflictError):
            self.service.ship_order("pending-1")

    def test_api_route_not_found_shape_is_preserved(self):
        self.assertEqual(
            self.api.handle("DELETE", "/orders/pending-1").body,
            {"error": "route_not_found"},
        )

    def test_cancel_pending_order_through_api(self):
        response = self.api.handle(
            "POST", "/orders/pending-1/cancel", '{"request_id":"cancel-123"}'
        )
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body["status"], "cancelled")
        events = self.repository.events_for("pending-1")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].kind, "cancelled")
        self.assertEqual(events[0].request_id, "cancel-123")


if __name__ == "__main__":
    unittest.main()
