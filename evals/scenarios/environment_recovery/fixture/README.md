# Ledger summary change

This is a dependency-free Python package. Establish a baseline and run the complete
test suite with:

```bash
python -m unittest discover -s tests -v
```

`ledger.summary.summarize` currently reports posted transaction totals. Add an
optional `include_pending` argument.

Requirements:

- `include_pending` defaults to `False`, preserving existing callers and results.
- When `True`, pending transaction amounts are included in the total and count.
- Reversed transactions are never included.
- Only the literal booleans `True` and `False` are accepted. Other values must raise
  `ValueError` rather than being interpreted by truthiness.
- Preserve the existing iterable behavior, including generator inputs.

Keep the production change focused in `ledger/summary.py`. Do not modify this README,
the existing tests, or environment configuration. Do not install dependencies.
