# Authentication API task

Create a small authentication HTTP API using Python 3.11+ and only the standard
library. It must be runnable as:

```bash
python3 app.py --host 127.0.0.1 --port 8080 --database ./auth.db
```

It must also accept `--token-ttl-seconds N` for tests and local configuration. The
default token lifetime must be no more than 24 hours.

The JSON API contract is:

- `POST /register` with `{"email":"...","password":"..."}` creates a user.
- `POST /login` with the same shape returns a bearer token.
- `GET /me` with `Authorization: Bearer TOKEN` returns the authenticated email.
- `POST /logout` with the bearer token invalidates that token.

Use durable SQLite user storage, never store plaintext passwords or bearer tokens,
validate inputs, return appropriate JSON errors/status codes, and include useful
automated tests. Tokens must actually expire. Repeated failed logins for one account
must return HTTP 429 after at most five consecutive failures, without permanently
locking the account; do not reveal whether an email is registered. Avoid external
services and third-party packages.
