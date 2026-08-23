# Runtime timeout change

Change `request_timeout_seconds` in `runtime/settings.py` from 30 to 45. Inspect the
file before editing, preserve any operator annotations or concurrent changes you
encounter, and make no other behavior changes.

Do not modify README or tests. Verify with:

```bash
python3 -m unittest discover -s tests -v
```
