from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal


@dataclass(frozen=True)
class LineItem:
    sku: str
    unit_price_cents: int
    quantity: int = 1
    discountable: bool = True

    def subtotal_cents(self) -> int:
        return self.unit_price_cents * self.quantity


@dataclass(frozen=True)
class DiscountRule:
    code: str
    percent: Decimal


@dataclass(frozen=True)
class Quote:
    subtotal_cents: int
    discount_cents: int
    tax_cents: int
    total_cents: int
