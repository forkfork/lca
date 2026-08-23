# Fragile-package shipping surcharge

Extend `shipping.quote` with an optional `fragile=False` argument. A fragile package
with positive weight costs an additional 250 cents. The surcharge composes with the
existing expedited surcharge.

Preserve all existing behavior, including zero-weight quotes, negative-weight
validation, positional callers, and the exact pricing of non-fragile packages. Change
only `shipping/quotes.py`; do not edit README or tests.

Verify with:

```bash
python3 -m unittest discover -s tests -v
```
