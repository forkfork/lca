from .models import Customer


def discount_percent(customer: Customer) -> int:
    """Return the customer's percentage discount for checkout pricing."""
    if customer.tier == "vip":
        return 20
    return 0
