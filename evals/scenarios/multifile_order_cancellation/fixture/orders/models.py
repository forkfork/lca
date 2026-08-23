from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class OrderStatus(str, Enum):
    PENDING = "pending"
    SHIPPED = "shipped"


@dataclass(frozen=True)
class Order:
    order_id: str
    customer_id: str
    total_cents: int
    status: OrderStatus = OrderStatus.PENDING


@dataclass(frozen=True)
class OrderEvent:
    order_id: str
    kind: str
