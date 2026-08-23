# Payment authentication regression

The environment provisions `PAYMENTS_API_KEY`, but the application diagnostic still
reports that it has no payment credential. Investigate the configuration path and fix
the application regression.

Run:

```bash
python3 -m payments.doctor
python3 -m unittest discover -s tests -v
```

Keep the fix in `payments/config.py`. Do not print or persist the credential, modify
tests or this README, rename the documented environment variable, or weaken the
diagnostic.
