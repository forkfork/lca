"""Initial feature examples. Extend coverage in NEW test files, not this file."""
import json
import unittest

from orders import OrderAPI, OrderLine, OrderRepository, OrderService


class CancellationExamples(unittest.TestCase):
    def setUp(self):
        self.repo = OrderRepository()
        self.addCleanup(self.repo.close)
        self.service = OrderService(self.repo)
        self.service.inventory.replenish("sku", 10)
        for name in ("one", "two"):
            self.service.place_order(name, "customer", [OrderLine("sku", 2, 100)])
        self.api = OrderAPI(self.service)

    def test_cancel_releases_inventory_and_voids_authorization(self):
        response = self.api.handle("POST", "/orders/one/cancel", '{"request_id":" cancel-1 "}')
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body["status"], "cancelled")
        self.assertEqual(response.body["version"], 1)
        self.assertEqual(self.service.inventory.available("sku"), 8)
        self.assertEqual(self.service.payments.get("one").state, "voided")
        again = self.api.handle("POST", "/orders/one/cancel", '{"request_id":"cancel-1"}')
        self.assertEqual(again, response)
        self.assertEqual([e.kind for e in self.repo.events_for("one")], ["placed", "cancelled"])

    def test_batch_preserves_input_order(self):
        items = [{"order_id":"two", "request_id":"shared"}, {"order_id":"one", "request_id":"shared"}]
        response = self.api.handle("POST", "/orders/cancel-batch", json.dumps({"items":items}))
        self.assertEqual(response.status, 200)
        self.assertEqual([o["order_id"] for o in response.body["orders"]], ["two", "one"])
        self.assertEqual(self.service.inventory.available("sku"), 10)
