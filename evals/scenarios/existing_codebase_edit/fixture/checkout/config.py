from __future__ import annotations

from decimal import Decimal, InvalidOperation
from typing import Any, Mapping

from .models import DiscountRule


def parse_discount_rule(data: Mapping[str, Any]) -> DiscountRule:
    code = data.get("code")
    if not isinstance(code, str) or not code.strip():
        raise ValueError("discount code must be a non-empty string")

    try:
        percent = Decimal(str(data["percent"]))
    except (KeyError, InvalidOperation, ValueError):
        raise ValueError("discount percent must be numeric") from None

    if not percent.is_finite() or percent < 0 or percent > 100:
        raise ValueError("discount percent must be between 0 and 100")

    return DiscountRule(code=code.strip(), percent=percent)
