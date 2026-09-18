"""Known-good oracle installer for grader tests ONLY; never part of the fixture."""
from pathlib import Path


def install(root):
    root=Path(root)
    def replace(name,old,new):
        p=root/'orders'/name;text=p.read_text();assert old in text,(name,old)
        p.write_text(text.replace(old,new,1))
    def append(name,text):
        p=root/'orders'/name;p.write_text(p.read_text()+text)
    replace('models.py','    SHIPPED = "shipped"','    SHIPPED = "shipped"\n    CANCELLED = "cancelled"')
    replace('migrations.py','))]', ''')), (2, (
    "CREATE TABLE cancellations (order_id TEXT REFERENCES orders(order_id), request_id TEXT NOT NULL, reason TEXT NOT NULL, response_json TEXT NOT NULL, PRIMARY KEY(order_id,request_id))",
))]''')
    append('repository.py','''

    def cancellation(self, order_id, request_id):
        return self.connection.execute("SELECT * FROM cancellations WHERE order_id=? AND request_id=?",
                                       (order_id, request_id)).fetchone()

    def save_cancellation(self, order, request_id, reason):
        from .serialization import order_body
        self.connection.execute("INSERT INTO cancellations VALUES (?,?,?,?)",
                                (order.order_id,request_id,reason,json.dumps(order_body(order),sort_keys=True)))
        self.db.checkpoint("cancellation_saved")
''')
    append('inventory.py','''

    def release(self, order_id):
        items = self.reservations_for(order_id)
        if any(item.state != "active" for item in items):
            raise ConflictError("reservations are not active")
        self.connection.execute("UPDATE reservations SET state='released' WHERE order_id=?", (order_id,))
        self.repository.db.checkpoint("inventory_released")
        return sum(item.quantity for item in items)
''')
    append('payments.py','''

    def void(self, order_id):
        payment = self.get(order_id)
        if payment is None:
            return 0
        if payment.state != "authorized":
            raise ConflictError("payment is not authorized")
        self.repository.connection.execute("UPDATE payments SET state='voided' WHERE order_id=?", (order_id,))
        self.repository.db.checkpoint("payment_voided")
        return payment.amount_cents
''')
    append('service.py','''

    @staticmethod
    def _cancel_input(order_id, request_id, reason, expected_version):
        order_id = identifier(order_id, "order_id")
        request_id = identifier(request_id, "request_id")
        if reason not in ("customer_request", "duplicate", "fraud"):
            raise ValueError("invalid cancellation reason")
        if expected_version is not None:
            integer(expected_version, "expected_version")
        return order_id, request_id, reason, expected_version

    def cancel_order(self, order_id, request_id, *, reason="customer_request", expected_version=None):
        import json
        from .serialization import order_from_body
        order_id, request_id, reason, expected_version = self._cancel_input(order_id,request_id,reason,expected_version)
        with self.repository.transaction():
            receipt = self.repository.cancellation(order_id,request_id)
            if receipt is not None:
                if receipt["reason"] != reason:
                    raise ConflictError("request ID has different reason")
                return order_from_body(json.loads(receipt["response_json"]))
            order = self.get_order(order_id)
            if order.status is not OrderStatus.PENDING:
                raise ConflictError("only pending orders can be cancelled")
            if expected_version is not None and expected_version != order.version:
                raise ConflictError("order version changed")
            units = self.inventory.release(order_id)
            amount = self.payments.void(order_id)
            cancelled = self.repository.set_status(order_id, OrderStatus.CANCELLED, order.version)
            payload = {"reason":reason, "released_units":units, "voided_cents":amount}
            self.repository.append_event(OrderEvent(order_id,"cancelled",request_id,payload))
            self.outbox.enqueue("order.cancelled",order_id,dict(payload,request_id=request_id,version=cancelled.version))
            self.repository.save_cancellation(cancelled,request_id,reason)
            return cancelled

    def cancel_orders(self, items):
        from .validation import object_body
        if not isinstance(items,list) or not 1 <= len(items) <= 50:
            raise ValueError("items must contain 1..50 requests")
        normalized = []
        seen = set()
        for item in items:
            item = object_body(item,{"order_id","request_id","reason","expected_version"},{"order_id","request_id"})
            values = self._cancel_input(item["order_id"],item["request_id"],item.get("reason","customer_request"),item.get("expected_version"))
            if values[0] in seen:
                raise ValueError("duplicate order ID")
            seen.add(values[0]); normalized.append(values)
        with self.repository.transaction():
            return [self.cancel_order(order_id,key,reason=reason,expected_version=version)
                    for order_id,key,reason,version in normalized]
''')
    replace('reporting.py','            key = "shipped_cents"', '            if order.status is OrderStatus.CANCELLED:\n                continue\n            key = "shipped_cents"')
    replace('api.py','            if method == "POST" and parts == ["orders"]:', '''            if method == "POST" and parts == ["orders", "cancel-batch"]:
                data = _json(body, {"items"}, {"items"})
                return Response(200, {"orders": [order_body(o) for o in self.service.cancel_orders(data["items"])]})
            if method == "POST" and parts == ["orders"]:''')
    replace('api.py','                if method == "POST" and action == "ship":', '''                if method == "POST" and action == "cancel":
                    data = _json(body, {"request_id", "reason", "expected_version"}, {"request_id"})
                    return Response(200, order_body(self.service.cancel_order(order_id, **data)))
                if method == "POST" and action == "ship":''')
    replace('cli.py','    commands.add_parser("inventory")', '''    sub = commands.add_parser("cancel")
    sub.add_argument("order_id")
    sub.add_argument("--request-id", required=True)
    sub.add_argument("--reason", default="customer_request")
    sub.add_argument("--expected-version", type=int)
    sub = commands.add_parser("cancel-batch")
    sub.add_argument("--items-json", required=True)
    commands.add_parser("inventory")''')
    replace('cli.py','        if args.command == "get":', '''        if args.command == "cancel":
            value = order_body(service.cancel_order(args.order_id,args.request_id,reason=args.reason,expected_version=args.expected_version))
        elif args.command == "cancel-batch":
            value = [order_body(o) for o in service.cancel_orders(json.loads(args.items_json))]
        elif args.command == "get":''')
    (root/'tests/test_cancellation_added.py').write_text('''import unittest
from orders import Order, OrderRepository, OrderService, ConflictError

class AddedCancellationTests(unittest.TestCase):
    def test_retry_reason_must_match(self):
        repo=OrderRepository([Order("one","c",10)])
        self.addCleanup(repo.close)
        service=OrderService(repo)
        first=service.cancel_order("one","r",reason="fraud")
        self.assertEqual(service.cancel_order("one"," r ",reason="fraud"),first)
        with self.assertRaises(ConflictError):
            service.cancel_order("one","r",reason="duplicate")
''')
