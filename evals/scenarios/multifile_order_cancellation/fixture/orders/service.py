from __future__ import annotations

from .errors import ConflictError, NotFoundError
from .inventory import Inventory
from .models import Order, OrderEvent, OrderStatus
from .outbox import Outbox
from .payments import Payments
from .repository import OrderRepository
from .validation import currency_code, identifier, integer, line_items


class OrderService:
    def __init__(self, repository: OrderRepository):
        self.repository = repository
        self.inventory = Inventory(repository)
        self.payments = Payments(repository)
        self.outbox = Outbox(repository)

    def get_order(self, order_id: str) -> Order:
        order = self.repository.get(order_id)
        if order is None:
            raise NotFoundError(f"order {order_id!r} was not found")
        return order

    def list_orders(self, customer_id: str) -> list[Order]:
        return self.repository.list_for_customer(customer_id)

    def place_order(self, order_id, customer_id, lines, *, shipping_cents=0, currency="AUD") -> Order:
        order_id = identifier(order_id, "order_id")
        customer_id = identifier(customer_id, "customer_id")
        items = line_items(lines)
        shipping = integer(shipping_cents, "shipping_cents")
        total = sum(line.subtotal_cents for line in items) + shipping
        order = Order(order_id, customer_id, total, currency=currency_code(currency),
                      lines=items, shipping_cents=shipping)
        with self.repository.transaction():
            self.repository.add(order)
            self.inventory.reserve(order)
            self.payments.authorize(order)
            self.repository.append_event(OrderEvent(order_id, "placed", payload={"total_cents": total}))
            self.outbox.enqueue("order.placed", order_id, {"total_cents": total})
        return order

    def pay_order(self, order_id: str) -> Order:
        with self.repository.transaction():
            order = self.get_order(order_id)
            if order.status is not OrderStatus.PENDING:
                raise ConflictError("only pending orders can be paid")
            captured = self.payments.capture(order_id)
            paid = self.repository.set_status(order_id, OrderStatus.PAID)
            self.repository.append_event(OrderEvent(order_id, "paid", payload={"captured_cents": captured}))
            self.outbox.enqueue("order.paid", order_id, {"captured_cents": captured})
            return paid

    def ship_order(self, order_id: str) -> Order:
        with self.repository.transaction():
            order = self.get_order(order_id)
            if order.status not in (OrderStatus.PENDING, OrderStatus.PAID):
                raise ConflictError("only pending or paid orders can be shipped")
            if order.status is OrderStatus.PENDING:
                self.payments.capture(order_id)
            units = self.inventory.commit(order_id)
            shipped = self.repository.set_status(order_id, OrderStatus.SHIPPED)
            self.repository.append_event(OrderEvent(order_id, "shipped", payload={"units": units}))
            self.outbox.enqueue("order.shipped", order_id, {"units": units})
            return shipped
