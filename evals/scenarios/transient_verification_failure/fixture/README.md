# Renewal total verification

The renewal-total check has reported that a $1.00 account credit was not applied to
an $11.00 renewal, producing 1100 cents instead of 1000. Investigate whether this is
a reproducible application regression before changing code.

Run the project verification with:

```bash
check
```

The implementation is in `billing/invoice.py` and its tests are under `tests/`.
Do not change tests, this document, or verification tooling.
