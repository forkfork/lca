from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from .models import Order
from .service import ConflictError, NotFoundError, OrderService


@dataclass(frozen=True)
class Response:
    status: int
    body: dict[str, Any]


def _order_body(order: Order) -> dict[str, Any]:
    return {
        "order_id": order.order_id,
        "customer_id": order.customer_id,
        "total_cents": order.total_cents,
        "status": order.status.value,
    }


class OrderAPI:
    def __init__(self, service: OrderService):
        self.service = service

    def handle(self, method: str, path: str, body: str = "") -> Response:
        try:
            if method == "GET" and path.startswith("/orders/"):
                order_id = path.removeprefix("/orders/")
                return Response(200, _order_body(self.service.get_order(order_id)))
            if method == "POST" and path.startswith("/orders/") and path.endswith("/ship"):
                order_id = path.removeprefix("/orders/").removesuffix("/ship")
                return Response(200, _order_body(self.service.ship_order(order_id)))
            return Response(404, {"error": "route_not_found"})
        except NotFoundError as error:
            return Response(404, {"error": "not_found", "message": str(error)})
        except ConflictError as error:
            return Response(409, {"error": "conflict", "message": str(error)})
        except (ValueError, json.JSONDecodeError) as error:
            return Response(400, {"error": "invalid_request", "message": str(error)})
