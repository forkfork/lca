"""Shared input rules. In particular bool is never an integer amount/version."""
from __future__ import annotations

from .models import OrderLine


def identifier(value: object, name: str, maximum: int = 64) -> str:
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > maximum:
        raise ValueError(f"{name} must be a nonempty string of at most {maximum} characters")
    return value.strip()


def integer(value: object, name: str, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise ValueError(f"{name} must be an integer >= {minimum}")
    return value


def currency_code(value: object) -> str:
    if value not in ("AUD", "USD", "EUR"):
        raise ValueError("unsupported currency")
    return str(value)


def line_items(values: object) -> tuple[OrderLine, ...]:
    if not isinstance(values, (list, tuple)) or not 1 <= len(values) <= 100:
        raise ValueError("lines must contain 1 to 100 items")
    output = []
    seen = set()
    for value in values:
        if isinstance(value, OrderLine):
            line = value
        elif isinstance(value, dict) and set(value) == {"sku", "quantity", "unit_price_cents"}:
            line = OrderLine(**value)
        else:
            raise ValueError("invalid line item")
        sku = identifier(line.sku, "sku")
        if sku in seen:
            raise ValueError("duplicate SKU")
        seen.add(sku)
        output.append(OrderLine(sku, integer(line.quantity, "quantity", 1),
                                integer(line.unit_price_cents, "unit_price_cents")))
    return tuple(output)


def object_body(value: object, allowed: set[str], required: set[str]) -> dict:
    if not isinstance(value, dict) or set(value) - allowed or required - set(value):
        raise ValueError("invalid object fields")
    return value
