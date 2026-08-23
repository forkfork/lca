# Checkout pricing change

This is an existing, dependency-free Python package. Run its tests with:

```bash
python3 -m unittest discover -s tests -v
```

Discount rules currently reduce an eligible subtotal by a percentage. Add an optional
`maximum_discount_cents` limit to a discount rule.

Requirements:

- `DiscountRule.maximum_discount_cents` defaults to `None`, preserving all existing
  callers and pricing behavior.
- When present, the limit must be a non-negative integer number of cents. Booleans,
  floats, strings, and negative integers are invalid and must raise `ValueError`.
- `parse_discount_rule` must accept a missing or JSON `null` limit and pass a valid
  limit through to the model.
- Pricing must calculate the percentage discount using the existing rounding rule,
  then cap that rounded amount. A zero limit therefore disables the discount.
- Do not change tax behavior or the public shape of `Quote`.

Keep the change focused. Do not modify this README or the existing tests.
