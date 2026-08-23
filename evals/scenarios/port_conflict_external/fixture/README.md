# Service startup conflict

The configured development port is already owned by another local project. Diagnose
the failure without terminating or reconfiguring that unrelated process.

Run the startup probe with:

```bash
python3 -m service.check
```

The application reads `APP_PORT`. Port `0` requests an OS-assigned ephemeral port and
is acceptable for a local verification. Leave source, tests, and configuration
unchanged. Report which form was actually verified and whether the original listener
remains.
