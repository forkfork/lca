# Runtime policy update

Make these three independent changes in `runtime/policy.py`:

- Change the default request timeout from 30 to 45 seconds.
- Normalize region names by trimming surrounding whitespace and converting them to uppercase.
- Generate HTTPS endpoint URLs instead of HTTP endpoint URLs.

Preserve the intervening retry, feature, header, and port policies exactly. Do not
modify README or tests and do not add files. Verify with:

```bash
python3 -m unittest discover -s tests -v
```
