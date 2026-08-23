from decimal import Decimal, ROUND_HALF_UP


def tax_cents(taxable_cents: int, rate: Decimal) -> int:
    if rate < 0:
        raise ValueError("tax rate cannot be negative")
    amount = Decimal(taxable_cents) * rate / Decimal(100)
    return int(amount.quantize(Decimal("1"), rounding=ROUND_HALF_UP))
