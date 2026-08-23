import math


BASE_CENTS = 500
PER_KILOGRAM_CENTS = 120
EXPEDITED_CENTS = 700
ZERO_WEIGHT_CENTS = 0


def quote(weight_grams: int, expedited: bool = False) -> int:
    """Return the shipping quote in cents."""
    if weight_grams < 0:
        raise ValueError("weight cannot be negative")
    if weight_grams == 0:
        return ZERO_WEIGHT_CENTS

    kilograms = math.ceil(weight_grams / 1000)
    total = BASE_CENTS + kilograms * PER_KILOGRAM_CENTS
    if expedited:
        total += EXPEDITED_CENTS
    return total
