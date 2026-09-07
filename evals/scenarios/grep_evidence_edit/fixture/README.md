# Diagnostic marker regression

The timeout diagnostic currently emits `legacy_timeout`, but downstream log parsers
now require `request_timeout`. Change only that marker. Preserve the public formatting
and every other diagnostic mapping.

Run verification with:

```bash
python3 -m unittest discover -s tests -v
```
