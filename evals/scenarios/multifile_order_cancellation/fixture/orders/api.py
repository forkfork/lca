from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from .errors import ConflictError, NotFoundError, StorageError
from .reporting import Reports
from .serialization import event_body, order_body
from .service import OrderService
from .validation import object_body


@dataclass(frozen=True)
class Response:
    status: int
    body: dict[str, Any]


def _json(body: str, allowed: set[str], required: set[str]) -> dict:
    try:
        return object_body(json.loads(body), allowed, required)
    except (TypeError, json.JSONDecodeError) as error:
        raise ValueError("body must be a JSON object") from error


class OrderAPI:
    def __init__(self, service: OrderService):
        self.service = service

    def handle(self, method: str, path: str, body: str = "") -> Response:
        try:
            parts = path.strip("/").split("/")
            if method == "POST" and parts == ["orders"]:
                data = _json(body, {"order_id", "customer_id", "lines", "shipping_cents", "currency"},
                             {"order_id", "customer_id", "lines"})
                return Response(201, order_body(self.service.place_order(**data)))
            if len(parts) == 3 and parts[0] == "customers" and parts[2] == "orders" and method == "GET":
                return Response(200, {"orders": [order_body(o) for o in self.service.list_orders(parts[1])]})
            if len(parts) == 3 and parts[0] == "customers" and parts[2] == "summary" and method == "GET":
                return Response(200, Reports(self.service.repository).customer_summary(parts[1]))
            if len(parts) == 2 and parts[0] == "orders" and method == "GET":
                return Response(200, order_body(self.service.get_order(parts[1])))
            if len(parts) == 3 and parts[0] == "orders":
                order_id, action = parts[1:]
                if method == "GET" and action == "events":
                    self.service.get_order(order_id)
                    return Response(200, {"events": [event_body(e) for e in self.service.repository.events_for(order_id)]})
                if method == "POST" and action == "ship":
                    return Response(200, order_body(self.service.ship_order(order_id)))
                if method == "POST" and action == "pay":
                    return Response(200, order_body(self.service.pay_order(order_id)))
            return Response(404, {"error": "route_not_found"})
        except NotFoundError as error:
            return Response(404, {"error": "not_found", "message": str(error)})
        except ConflictError as error:
            return Response(409, {"error": "conflict", "message": str(error)})
        except ValueError as error:
            return Response(400, {"error": "invalid_request", "message": str(error)})
        except StorageError:
            return Response(503, {"error": "storage_unavailable"})
