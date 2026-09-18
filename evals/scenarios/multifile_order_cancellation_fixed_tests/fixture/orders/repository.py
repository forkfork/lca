from __future__ import annotations

import json

from .database import Database
from .errors import ConflictError
from .models import Order, OrderEvent, OrderLine, OrderStatus


class OrderRepository:
    def __init__(self, orders: list[Order] | None = None, *, database: str = ":memory:", fault=None):
        self.db = Database(database, fault)
        with self.transaction():
            for order in orders or []:
                self.add(order)

    @property
    def connection(self):
        return self.db.connection

    def transaction(self):
        return self.db.transaction()

    def close(self) -> None:
        self.db.close()

    def add(self, order: Order) -> None:
        if self.get(order.order_id) is not None:
            raise ConflictError("order already exists")
        self.connection.execute("INSERT INTO orders VALUES (?,?,?,?,?,?,?)", (
            order.order_id, order.customer_id, order.total_cents, order.status.value,
            order.version, order.currency, order.shipping_cents,
        ))
        self.connection.executemany("INSERT INTO order_lines VALUES (?,?,?,?,?)", (
            (order.order_id, position, line.sku, line.quantity, line.unit_price_cents)
            for position, line in enumerate(order.lines)
        ))
        self.db.checkpoint("order_added")

    def _decode(self, row) -> Order:
        lines = tuple(OrderLine(r["sku"], r["quantity"], r["unit_price_cents"])
                      for r in self.connection.execute(
                          "SELECT * FROM order_lines WHERE order_id=? ORDER BY position", (row["order_id"],)))
        return Order(row["order_id"], row["customer_id"], row["total_cents"],
                     OrderStatus(row["status"]), row["version"], row["currency"],
                     lines, row["shipping_cents"])

    def get(self, order_id: str) -> Order | None:
        row = self.connection.execute("SELECT * FROM orders WHERE order_id=?", (order_id,)).fetchone()
        return self._decode(row) if row else None

    def list_for_customer(self, customer_id: str) -> list[Order]:
        return [self._decode(row) for row in self.connection.execute(
            "SELECT * FROM orders WHERE customer_id=? ORDER BY order_id", (customer_id,))]

    def all(self) -> list[Order]:
        return [self._decode(row) for row in self.connection.execute("SELECT * FROM orders ORDER BY order_id")]

    def set_status(self, order_id: str, status: OrderStatus, expected_version: int | None = None) -> Order:
        current = self.get(order_id)
        if current is None:
            raise KeyError(order_id)
        version = current.version if expected_version is None else expected_version
        changed = self.connection.execute(
            "UPDATE orders SET status=?,version=version+1 WHERE order_id=? AND version=?",
            (status.value, order_id, version),
        ).rowcount
        if not changed:
            raise ConflictError("order version changed")
        self.db.checkpoint("order_status")
        return self.get(order_id)

    def append_event(self, event: OrderEvent) -> None:
        self.connection.execute("INSERT INTO events(order_id,kind,request_id,payload) VALUES (?,?,?,?)",
                                (event.order_id, event.kind, event.request_id, json.dumps(event.payload, sort_keys=True)))
        self.db.checkpoint("event_appended")

    def events_for(self, order_id: str) -> list[OrderEvent]:
        return [OrderEvent(row["order_id"], row["kind"], row["request_id"],
                           json.loads(row["payload"]), row["sequence"])
                for row in self.connection.execute(
                    "SELECT * FROM events WHERE order_id=? ORDER BY sequence", (order_id,))]
