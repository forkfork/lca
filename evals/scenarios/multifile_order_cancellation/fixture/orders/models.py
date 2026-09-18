from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class OrderStatus(str, Enum):
    PENDING = "pending"
    PAID = "paid"
    SHIPPED = "shipped"


@dataclass(frozen=True)
class OrderLine:
    sku: str
    quantity: int
    unit_price_cents: int

    @property
    def subtotal_cents(self) -> int:
        return self.quantity * self.unit_price_cents


@dataclass(frozen=True)
class Order:
    order_id: str
    customer_id: str
    total_cents: int
    status: OrderStatus = OrderStatus.PENDING
    version: int = 0
    currency: str = "AUD"
    lines: tuple[OrderLine, ...] = ()
    shipping_cents: int = 0


@dataclass(frozen=True)
class OrderEvent:
    order_id: str
    kind: str
    request_id: str | None = None
    payload: dict[str, Any] = field(default_factory=dict)
    sequence: int = 0


@dataclass(frozen=True)
class Payment:
    order_id: str
    amount_cents: int
    state: str
    currency: str


@dataclass(frozen=True)
class Reservation:
    order_id: str
    sku: str
    quantity: int
    state: str


@dataclass(frozen=True)
class OutboxMessage:
    message_id: int
    topic: str
    aggregate_id: str
    payload: dict[str, Any]
    delivered: bool


@dataclass(frozen=True)
class ReturnRecord:
    return_id: str
    order_id: str
    amount_cents: int
    reason: str
