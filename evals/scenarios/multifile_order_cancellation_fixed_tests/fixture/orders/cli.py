"""Local operations CLI. stdout is one JSON value; errors go to stderr."""
from __future__ import annotations

import argparse
import json
import sys

from .errors import ConflictError, NotFoundError, StorageError
from .reporting import Reports
from .repository import OrderRepository
from .serialization import event_body, order_body
from .service import OrderService


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="orders")
    result.add_argument("--database", required=True)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("get", "ship", "pay", "events"):
        sub = commands.add_parser(name)
        sub.add_argument("order_id")
    for name in ("list", "summary"):
        sub = commands.add_parser(name)
        sub.add_argument("customer_id")
    sub = commands.add_parser("stock")
    sub.add_argument("sku")
    sub.add_argument("quantity", type=int)
    commands.add_parser("inventory")
    return result


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    repo = OrderRepository(database=args.database)
    service = OrderService(repo)
    try:
        if args.command == "get":
            value = order_body(service.get_order(args.order_id))
        elif args.command == "ship":
            value = order_body(service.ship_order(args.order_id))
        elif args.command == "pay":
            value = order_body(service.pay_order(args.order_id))
        elif args.command == "events":
            service.get_order(args.order_id)
            value = [event_body(e) for e in repo.events_for(args.order_id)]
        elif args.command == "list":
            value = [order_body(o) for o in service.list_orders(args.customer_id)]
        elif args.command == "summary":
            value = Reports(repo).customer_summary(args.customer_id)
        elif args.command == "stock":
            service.inventory.replenish(args.sku, args.quantity)
            value = {"sku": args.sku, "available": service.inventory.available(args.sku)}
        else:
            value = Reports(repo).inventory_summary()
        print(json.dumps(value, sort_keys=True))
        return 0
    except (NotFoundError, ConflictError, ValueError, StorageError) as error:
        print(json.dumps({"error": type(error).__name__, "message": str(error)}), file=sys.stderr)
        return 2
    finally:
        repo.close()
