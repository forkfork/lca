from .models import LineItem


class QuoteCache:
    def __init__(self) -> None:
        self._quotes: dict[tuple, int] = {}

    @staticmethod
    def key(items: list[LineItem]) -> tuple:
        return tuple((item.sku, item.unit_price_cents, item.quantity) for item in items)

    def get(self, key: tuple) -> int | None:
        return self._quotes.get(key)

    def put(self, key: tuple, total_cents: int) -> None:
        self._quotes[key] = total_cents

    def __len__(self) -> int:
        return len(self._quotes)
