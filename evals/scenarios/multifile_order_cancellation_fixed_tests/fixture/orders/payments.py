from __future__ import annotations

from .errors import ConflictError
from .models import Order, Payment


class Payments:
    """Local authorization ledger; no external gateway or network calls."""
    def __init__(self, repository):
        self.repository = repository

    def get(self, order_id: str) -> Payment | None:
        row = self.repository.connection.execute("SELECT * FROM payments WHERE order_id=?", (order_id,)).fetchone()
        return Payment(row["order_id"], row["amount_cents"], row["state"], row["currency"]) if row else None

    def authorize(self, order: Order) -> None:
        if self.get(order.order_id) is not None:
            raise ConflictError("payment already exists")
        self.repository.connection.execute("INSERT INTO payments VALUES (?,?,'authorized',?)",
                                           (order.order_id, order.total_cents, order.currency))
        self.repository.db.checkpoint("payment_authorized")

    def capture(self, order_id: str) -> int:
        payment = self.get(order_id)
        if payment is None:
            return 0  # Imported legacy orders may have no local authorization.
        if payment.state != "authorized":
            raise ConflictError("payment is not authorized")
        self.repository.connection.execute("UPDATE payments SET state='captured' WHERE order_id=?", (order_id,))
        self.repository.db.checkpoint("payment_captured")
        return payment.amount_cents
