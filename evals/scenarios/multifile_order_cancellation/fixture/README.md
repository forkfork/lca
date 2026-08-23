# Order workflow change

This is an existing, dependency-free Python package with model, repository, service,
and transport layers. Run its tests with:

```bash
python3 -m unittest discover -s tests -v
```

Add idempotent order cancellation through both the service and JSON API.

Requirements:

- `OrderService.cancel_order(order_id, request_id)` cancels a pending order and
  returns the updated order.
- Cancellation records one `OrderEvent` with kind `"cancelled"` and the supplied
  request ID.
- Retrying the same request ID for the same order returns the cancelled order without
  adding another event. Reusing a request ID for a different order is allowed.
- Cancelling a shipped order, or cancelling an already-cancelled order with a
  different request ID, raises the existing `ConflictError`.
- Unknown orders raise the existing `NotFoundError`.
- A request ID must be a non-empty string after trimming and at most 64 characters.
  Trim it before storing or comparing it, so surrounding whitespace is not part of
  its identity. Invalid values raise `ValueError` and never mutate repository state.
- `POST /orders/{order_id}/cancel` accepts JSON `{"request_id":"..."}` and returns
  the normal order representation with HTTP 200. Map invalid JSON/input to 400,
  missing orders to 404, and conflicts to 409 using the API's existing error shape.
- Preserve all existing query and shipping behavior and public imports.

Keep the change focused. Do not modify this README or the existing tests, and do not
add third-party dependencies.
