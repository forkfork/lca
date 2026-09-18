from __future__ import annotations

from collections import Counter
from .models import OrderStatus


class Reports:
    def __init__(self, repository):
        self.repository = repository

    def customer_summary(self, customer_id: str) -> dict:
        orders = self.repository.list_for_customer(customer_id)
        counts = Counter(order.status.value for order in orders)
        totals = {}
        for order in orders:
            totals.setdefault(order.currency, {"open_cents": 0, "shipped_cents": 0})
            key = "shipped_cents" if order.status is OrderStatus.SHIPPED else "open_cents"
            totals[order.currency][key] += order.total_cents
        return {"customer_id": customer_id, "order_count": len(orders),
                "status_counts": dict(sorted(counts.items())), "totals": totals}

    def inventory_summary(self) -> list[dict]:
        from .inventory import Inventory
        inventory = Inventory(self.repository)
        return [{"sku": row["sku"], "on_hand": row["on_hand"],
                 "available": inventory.available(row["sku"])}
                for row in self.repository.connection.execute("SELECT * FROM stock ORDER BY sku")]
