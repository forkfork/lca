from __future__ import annotations

from dataclasses import replace

from .models import Order, OrderEvent, OrderStatus


class OrderRepository:
    def __init__(self, orders: list[Order] | None = None):
        self._orders = {order.order_id: order for order in orders or []}
        self._events: list[OrderEvent] = []

    def get(self, order_id: str) -> Order | None:
        return self._orders.get(order_id)

    def list_for_customer(self, customer_id: str) -> list[Order]:
        return [
            order for order in self._orders.values()
            if order.customer_id == customer_id
        ]

    def set_status(self, order_id: str, status: OrderStatus) -> Order:
        current = self._orders[order_id]
        updated = replace(current, status=status)
        self._orders[order_id] = updated
        return updated

    def append_event(self, event: OrderEvent) -> None:
        self._events.append(event)

    def events_for(self, order_id: str) -> list[OrderEvent]:
        return [event for event in self._events if event.order_id == order_id]
