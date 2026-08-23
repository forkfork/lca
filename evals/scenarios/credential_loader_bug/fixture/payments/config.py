from __future__ import annotations

import os
from collections.abc import Mapping


def api_key(environment: Mapping[str, str] | None = None) -> str | None:
    values = os.environ if environment is None else environment
    return values.get("PAYMENT_API_KEY")


def endpoint() -> str:
    return "https://payments.example.test/v1"
