from .cache import QuoteCache
from .discounts import discount_percent
from .models import Customer, LineItem


class QuoteService:
    def __init__(self) -> None:
        self.cache = QuoteCache()

    def quote(self, customer: Customer, items: list[LineItem]) -> int:
        key = self.cache.key(items)
        cached = self.cache.get(key)
        if cached is not None:
            return cached

        subtotal = sum(item.subtotal_cents() for item in items)
        percent = discount_percent(customer)
        total = subtotal - subtotal * percent // 100
        self.cache.put(key, total)
        return total
