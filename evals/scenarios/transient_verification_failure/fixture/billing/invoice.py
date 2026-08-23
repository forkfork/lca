def renewal_total(subtotal_cents: int, credit_cents: int = 0) -> int:
    if subtotal_cents < 0 or credit_cents < 0:
        raise ValueError("amounts must be non-negative")
    return max(0, subtotal_cents - credit_cents)
