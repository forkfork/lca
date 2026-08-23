from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class Transaction:
    amount_cents: int
    status: str = "posted"


def summarize(transactions: Iterable[Transaction]) -> tuple[int, int]:
    included = [transaction for transaction in transactions if transaction.status == "posted"]
    return sum(transaction.amount_cents for transaction in included), len(included)
