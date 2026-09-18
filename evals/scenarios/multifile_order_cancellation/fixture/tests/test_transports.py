import json
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

from orders import Order, OrderAPI, OrderRepository, OrderService


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = str(Path(self.tmp.name) / "orders.db")
        self.repo = OrderRepository([Order("legacy", "alice", 900)], database=self.path)
        self.addCleanup(self.repo.close)
        self.service = OrderService(self.repo)
        self.service.inventory.replenish("sku", 20)
        self.api = OrderAPI(self.service)

    def cli(self, *args):
        return subprocess.run([sys.executable, "-m", "orders", "--database", self.path, *args],
                              capture_output=True, text=True, timeout=10)

    def test_api_place_and_read(self):
        response = self.api.handle("POST", "/orders", json.dumps({"order_id":"new", "customer_id":"alice",
                                   "lines":[{"sku":"sku", "quantity":2, "unit_price_cents":40}]}))
        self.assertEqual(response.status, 201)
        self.assertEqual(response.body["total_cents"], 80)
        self.assertEqual(self.api.handle("GET", "/orders/new").body, response.body)
        self.assertEqual(len(self.api.handle("GET", "/customers/alice/orders").body["orders"]), 2)

    def test_api_shapes_and_routes(self):
        for method, route, status, error in [("GET", "/orders/nope", 404, "not_found"),
                                            ("DELETE", "/orders/legacy", 404, "route_not_found"),
                                            ("GET", "/orders/legacy/ship", 404, "route_not_found")]:
            response = self.api.handle(method, route)
            self.assertEqual((response.status, response.body["error"]), (status, error))
        for body in ('{', '[]', 'null', '{}', '{"unexpected":1}'):
            self.assertEqual(self.api.handle("POST", "/orders", body).status, 400)

    def test_api_shipping_and_audit(self):
        self.assertEqual(self.api.handle("POST", "/orders/legacy/ship").status, 200)
        self.assertEqual(self.api.handle("POST", "/orders/legacy/ship").status, 409)
        events = self.api.handle("GET", "/orders/legacy/events").body["events"]
        self.assertEqual(events[0]["kind"], "shipped")
        self.assertEqual(self.api.handle("GET", "/orders/absent/events").status, 404)

    def test_cli_get_list_ship(self):
        result = self.cli("get", "legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "pending")
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(self.cli("list", "alice").stdout)[0]["order_id"], "legacy")
        self.assertEqual(json.loads(self.cli("ship", "legacy").stdout)["status"], "shipped")
        self.assertEqual(json.loads(self.cli("events", "legacy").stdout)[0]["kind"], "shipped")

    def test_cli_domain_failure_is_json_stderr(self):
        result = self.cli("get", "missing")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(json.loads(result.stderr)["error"], "NotFoundError")

    def test_cli_stock_and_inventory(self):
        result = self.cli("stock", "sku", "3")
        self.assertEqual(json.loads(result.stdout)["available"], 23)
        self.assertEqual(json.loads(self.cli("inventory").stdout)[0]["on_hand"], 23)
        self.assertEqual(self.cli("stock", "sku", "-1").returncode, 2)
