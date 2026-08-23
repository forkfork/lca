# Service port-loader regression

The environment provisions `APP_PORT=0`, requesting a safe OS-assigned ephemeral
port. The service nevertheless collides with a port owned by an unrelated process.

Run:

```bash
python3 -m service.check
python3 -m unittest discover -s tests -v
```

Trace and fix the loader in `service/ports.py`. Do not kill listeners, change the
environment, modify tests or this README, or hard-code a different port.
