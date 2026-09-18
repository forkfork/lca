from __future__ import annotations

from .models import Order, OrderLine, OrderStatus


def order_body(order: Order) -> dict:
    """Stable wire/storage representation; CLI and API share this contract."""
    return {
        "order_id": order.order_id,
        "customer_id": order.customer_id,
        "total_cents": order.total_cents,
        "status": order.status.value,
        "version": order.version,
        "currency": order.currency,
        "shipping_cents": order.shipping_cents,
        "lines": [{"sku": line.sku, "quantity": line.quantity,
                   "unit_price_cents": line.unit_price_cents} for line in order.lines],
    }


def order_from_body(value: dict) -> Order:
    return Order(value["order_id"], value["customer_id"], value["total_cents"],
                 OrderStatus(value["status"]), value["version"], value["currency"],
                 tuple(OrderLine(**line) for line in value["lines"]), value["shipping_cents"])


def event_body(event) -> dict:
    return {"sequence": event.sequence, "order_id": event.order_id, "kind": event.kind,
            "request_id": event.request_id, "payload": event.payload}
