from dataclasses import dataclass


@dataclass
class Customer:
    customer_id: str
    tier: str = "regular"


@dataclass(frozen=True)
class LineItem:
    sku: str
    unit_price_cents: int
    quantity: int = 1

    def subtotal_cents(self) -> int:
        return self.unit_price_cents * self.quantity
