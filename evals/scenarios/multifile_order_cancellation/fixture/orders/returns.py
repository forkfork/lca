from __future__ import annotations

from .errors import ConflictError, NotFoundError
from .models import OrderEvent, OrderStatus, ReturnRecord
from .outbox import Outbox
from .validation import identifier, integer


class Returns:
    """Post-shipment refunds are a separate workflow from pre-shipment cancellation."""
    def __init__(self, repository):
        self.repository = repository

    def refund(self, return_id: str, order_id: str, amount_cents: int, reason: str) -> ReturnRecord:
        return_id = identifier(return_id, "return_id")
        reason = identifier(reason, "reason", 200)
        amount = integer(amount_cents, "amount_cents", 1)
        with self.repository.transaction():
            row = self.repository.connection.execute("SELECT * FROM returns WHERE return_id=?", (return_id,)).fetchone()
            if row:
                record = ReturnRecord(row["return_id"], row["order_id"], row["amount_cents"], row["reason"])
                if record != ReturnRecord(return_id, order_id, amount, reason):
                    raise ConflictError("return ID has different parameters")
                return record
            order = self.repository.get(order_id)
            if order is None:
                raise NotFoundError(order_id)
            if order.status is not OrderStatus.SHIPPED:
                raise ConflictError("only shipped orders can be returned")
            refunded = self.repository.connection.execute(
                "SELECT COALESCE(SUM(amount_cents),0) FROM returns WHERE order_id=?", (order_id,)).fetchone()[0]
            if refunded + amount > order.total_cents:
                raise ConflictError("refund exceeds order total")
            self.repository.connection.execute("INSERT INTO returns VALUES (?,?,?,?)", (return_id, order_id, amount, reason))
            self.repository.append_event(OrderEvent(order_id, "refunded", return_id, {"amount_cents": amount}))
            Outbox(self.repository).enqueue("order.refunded", order_id, {"amount_cents": amount})
            return ReturnRecord(return_id, order_id, amount, reason)
