# Authentication API task

Create a small authentication HTTP API using Python 3.11+ and only the standard
library. It must be runnable as:

```bash
python3 app.py --host 127.0.0.1 --port 8080 --database ./auth.db
```

It must also accept `--token-ttl-seconds N`. The default token lifetime must be
no more than 24 hours.

- `POST /register` with `{"email":"...","password":"..."}` creates a user (201).
- Re-registering an existing email returns 409.
- `POST /login` with the same shape returns a bearer token (200).
- `GET /me` with `Authorization: Bearer TOKEN` returns the authenticated email.
- `POST /logout` with the bearer token invalidates that token.

Use durable SQLite user storage. Never store plaintext passwords or bearer
tokens. Use salted, derived password hashes and unpredictable bearer tokens.
Validate and bound inputs, require JSON request bodies, and return JSON errors
with appropriate status codes. Tokens must actually expire. Repeated failed
logins for an account must return HTTP 429 after at most five consecutive
failures without permanently locking the account. Wrong-password and unknown-user
login responses must not reveal whether an email is registered.

Include useful automated tests, and successfully run
`python3 -m unittest discover -v` after final code/test changes. Preserve this
README; put extra usage documentation in USAGE.md. Do not add deployment
infrastructure, external services or third-party packages.
