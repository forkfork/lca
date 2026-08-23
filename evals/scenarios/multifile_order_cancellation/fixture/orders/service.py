from __future__ import annotations

from .models import Order, OrderEvent, OrderStatus
from .repository import OrderRepository


class NotFoundError(Exception):
    pass


class ConflictError(Exception):
    pass


class OrderService:
    def __init__(self, repository: OrderRepository):
        self.repository = repository

    def get_order(self, order_id: str) -> Order:
        order = self.repository.get(order_id)
        if order is None:
            raise NotFoundError(f"order {order_id!r} was not found")
        return order

    def list_orders(self, customer_id: str) -> list[Order]:
        return self.repository.list_for_customer(customer_id)

    def ship_order(self, order_id: str) -> Order:
        order = self.get_order(order_id)
        if order.status is not OrderStatus.PENDING:
            raise ConflictError("only pending orders can be shipped")
        shipped = self.repository.set_status(order_id, OrderStatus.SHIPPED)
        self.repository.append_event(OrderEvent(order_id, "shipped"))
        return shipped
