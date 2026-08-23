from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP
from typing import Iterable

from .models import DiscountRule, LineItem, Quote
from .tax import tax_cents


def _rounded_percentage(cents: int, percent: Decimal) -> int:
    amount = Decimal(cents) * percent / Decimal(100)
    return int(amount.quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def quote(
    items: Iterable[LineItem],
    discount: DiscountRule | None = None,
    tax_rate: Decimal = Decimal("0"),
) -> Quote:
    materialized = list(items)
    subtotal = sum(item.subtotal_cents() for item in materialized)
    eligible = sum(
        item.subtotal_cents() for item in materialized if item.discountable
    )

    discount_amount = 0
    if discount is not None:
        discount_amount = _rounded_percentage(eligible, discount.percent)

    taxable = subtotal - discount_amount
    tax_amount = tax_cents(taxable, tax_rate)
    return Quote(
        subtotal_cents=subtotal,
        discount_cents=discount_amount,
        tax_cents=tax_amount,
        total_cents=taxable + tax_amount,
    )
