from __future__ import annotations

from .errors import ConflictError
from .models import Order, Reservation
from .validation import identifier, integer


class Inventory:
    def __init__(self, repository):
        self.repository = repository

    @property
    def connection(self):
        return self.repository.connection

    def replenish(self, sku: str, quantity: int) -> None:
        sku = identifier(sku, "sku")
        quantity = integer(quantity, "quantity", 1)
        self.connection.execute(
            "INSERT INTO stock VALUES (?,?) ON CONFLICT(sku) DO UPDATE SET on_hand=on_hand+excluded.on_hand",
            (sku, quantity),
        )

    def available(self, sku: str) -> int:
        row = self.connection.execute("SELECT on_hand FROM stock WHERE sku=?", (sku,)).fetchone()
        if row is None:
            return 0
        reserved = self.connection.execute(
            "SELECT COALESCE(SUM(quantity),0) FROM reservations WHERE sku=? AND state='active'", (sku,)
        ).fetchone()[0]
        return row[0] - reserved

    def reservations_for(self, order_id: str) -> list[Reservation]:
        return [Reservation(row["order_id"], row["sku"], row["quantity"], row["state"])
                for row in self.connection.execute(
                    "SELECT * FROM reservations WHERE order_id=? ORDER BY sku", (order_id,))]

    def reserve(self, order: Order) -> None:
        for line in order.lines:
            if self.available(line.sku) < line.quantity:
                raise ConflictError(f"insufficient stock for {line.sku}")
            self.connection.execute("INSERT INTO reservations VALUES (?,?,?,'active')",
                                    (order.order_id, line.sku, line.quantity))
        self.repository.db.checkpoint("inventory_reserved")

    def commit(self, order_id: str) -> int:
        reservations = self.reservations_for(order_id)
        if any(item.state != "active" for item in reservations):
            raise ConflictError("reservations are not active")
        for item in reservations:
            self.connection.execute("UPDATE stock SET on_hand=on_hand-? WHERE sku=?", (item.quantity, item.sku))
        self.connection.execute("UPDATE reservations SET state='committed' WHERE order_id=?", (order_id,))
        self.repository.db.checkpoint("inventory_committed")
        return sum(item.quantity for item in reservations)
