from __future__ import annotations

import os
from collections.abc import Mapping


def configured_port(environment: Mapping[str, str] | None = None) -> int:
    values = os.environ if environment is None else environment
    port = int(values.get("APP_PORT", "8000"))
    if not 0 <= port <= 65535:
        raise ValueError("APP_PORT must be between 0 and 65535")
    return port
