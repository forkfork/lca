# Order operations: durable cancellation (fixture version 2)

This is an existing Python 3.11+ standard-library application. It has a SQLite
repository, inventory reservations, payment authorizations, shipment/return
workflows, an audit log, an outbox, an in-process JSON API, and a CLI. The feature
is durable, idempotent cancellation of pending orders, individually or in a batch.

Run the complete suite from this project root:

```sh
python3 -m unittest discover -s tests -v
```

Existing regression tests must keep passing. `tests/test_cancellation.py` contains
initial feature acceptance tests which fail until cancellation is implemented.
The full cancellation contract is supplied in `tests/test_cancellation_contract.py`.
Do not add, modify, or delete tests or test data. Modify only existing Python files
under `orders/`, preserving public imports and existing methods. Do not modify
this README. Use workspace-relative paths when editing. Do not add dependencies, services, or deployment files.
After the final production-source change, run the complete suite above successfully.
Use the available source-editing tools for source changes so edit-tool behavior
can be measured. Use read/find/grep for inspection. Shell commands are limited to
the documented full unittest command above (an optional Python `-B` flag is allowed).

## Existing architecture

- `models.py`, `serialization.py`, `validation.py`: immutable values and input rules.
- `database.py`, `migrations.py`, `repository.py`: SQLite connections, nested
  transactions, append-only migrations, order versions, durable audit records.
- `inventory.py`, `payments.py`, `outbox.py`: related state in the same database.
- `service.py`: command transactions. Placement reserves stock and authorizes
  payment; shipping commits stock and captures payment; paying alone keeps stock
  reserved. Imported legacy orders can have no lines, reservations or payment.
- `returns.py`: post-shipment refunds, which must remain separate and functional.
- `reporting.py`, `api.py`, `cli.py`: customer summaries and transport adapters.

The database has no network dependencies. Each repository owns its connection;
multiple processes/connections may open the same file. Transaction boundaries
must cover every effect of a command. `Database.checkpoint(name)` calls a fault
hook after writes for rollback tests; preserve existing hooks.

## Single cancellation

Implement `OrderService.cancel_order(order_id, request_id, *,
reason="customer_request", expected_version=None) -> Order`.

- Request IDs are strings, nonempty after trimming, at most 64 characters after
  trimming. Trim it before storing or comparing it. Reject nonstrings and invalid
  IDs with ValueError before any mutation.
- Reasons are exactly `customer_request`, `duplicate`, or `fraud`. No implicit
  coercion. expected_version is None or a nonnegative integer (bool is invalid).
- Unknown orders raise NotFoundError. Only PENDING orders may be newly cancelled;
  PAID, SHIPPED and already-cancelled orders with a new request raise ConflictError.
- Add OrderStatus.CANCELLED (`cancelled`). A successful cancellation increments
  the order version exactly once and preserves all other order fields/lines.
- A supplied expected_version must equal the current version for a NEW command.
- Idempotency is scoped to (order_id, normalized request_id). The same request on
  another order is independent. Retry with the same reason returns the ORIGINAL
  saved Order snapshot, even after reconnect/restart or later unrelated changes.
  Retry with a different reason conflicts. A valid but old expected_version must
  not break a matching retry; validate its type first, then consult the receipt.
- Release active reservations for that order (state `released`) without changing
  physical stock or another order's reservations. A legacy order with no
  reservations releases zero units. Existing non-active reservations conflict.
- Void an authorized payment (state `voided`) without changing amount/currency.
  Missing legacy payment means zero voided cents. Captured/already-voided payment
  conflicts on a new cancellation. No refund or external gateway call occurs.
- Append exactly one OrderEvent kind `cancelled`, normalized request_id, and
  payload `{"reason": reason, "released_units": N, "voided_cents": M}`.
- Enqueue exactly one outbox message topic `order.cancelled`, aggregate_id equal
  to order_id, with that payload plus `request_id` and the new `version`.
- Persist the receipt in a new `cancellations` table using an APPENDED migration
  version 2. Columns: order_id, request_id, reason, response_json; composite
  primary key (order_id, request_id). response_json is order_body(cancelled).
  Upgrade real version-1 databases without losing orders, lines, stock, payments,
  reservations, events, outbox or returns. Reopening is safe and idempotent.
- The status, inventory, payment, event, outbox and receipt writes are one atomic
  transaction. On failure, roll back everything and allow a later retry.
  New checkpoints: `inventory_released`, `payment_voided`, `cancellation_saved`,
  each AFTER its write. Preserve `order_status`, `event_appended`, `outbox_enqueued`.
  Do not swallow StorageError. Concurrent same-key callers must produce one effect
  and the same result; concurrent different-key callers have one winner.

## Batch cancellation

Implement `OrderService.cancel_orders(items) -> list[Order]`. items is a list of
1..50 dicts with required order_id/request_id and optional reason/expected_version.
Reject unknown fields, invalid fields and duplicate order IDs with ValueError.
Validate the ENTIRE input before mutation. Process in input order and return in
that order. Apply the same single-order semantics. All new effects of the batch
are atomic: one conflict/not-found/storage failure rolls them all back. Existing
receipts from before the batch remain intact. Retrying an identical batch must
not add events/messages or release/void twice. Batch and single commands must
share the same business logic, not diverging implementations.

## API and CLI

- POST `/orders/{id}/cancel`: JSON object requiring request_id and allowing reason
  and expected_version. Return HTTP 200 with order_body(Order), unchanged shape.
- POST `/orders/cancel-batch`: JSON object containing ONLY `items`. Return HTTP 200
  with `{"orders": [order_body(order), ...]}` in input order.
- Malformed JSON, nonobject bodies, unknown/missing fields and invalid values =>
  400 `invalid_request`; missing order => 404 `not_found`; conflicts => 409
  `conflict`; injected StorageError => 503 `storage_unavailable`. Preserve existing
  error message conventions and route/method behavior.
- `python3 -m orders --database PATH cancel ORDER_ID --request-id ID
  [--reason REASON] [--expected-version N]`: one Order JSON on stdout, exit 0.
- `python3 -m orders --database PATH cancel-batch --items-json JSON`: JSON array of
  Orders on stdout, exit 0. Parse items directly from this JSON argument.
- Domain/validation failures: JSON error on stderr, empty stdout, exit 2, no partial
  writes. Preserve all existing commands. Handle malformed batch JSON too.

## Reporting and compatibility

Customer summary keeps counting cancelled orders in order_count/status_counts,
but excludes their totals from BOTH open_cents and shipped_cents. Preserve a
currency bucket with zero totals even when all its orders are cancelled. Legacy
pending/paid/shipped behavior, customer separation, ordered queries, serializers,
shipping, returns, outbox delivery and all existing public imports must work.

This task is about changing a working layered system. Avoid replacing the package
with a separate implementation or weakening existing validation/tests.
