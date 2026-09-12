#!/usr/bin/env python3
"""Transfer only a current Codex access token after launch, via AWS shell."""
import base64
import json
from pathlib import Path
import sys
import time

from websockets.sync.client import connect
from shell import aws


def wait_for(ws, marker):
    data = b""
    deadline = time.monotonic() + 20
    while marker not in data:
        chunk = ws.recv(timeout=max(0.1, deadline - time.monotonic()))
        data += chunk.encode() if isinstance(chunk, str) else chunk


if len(sys.argv) not in (2, 3):
    raise SystemExit("Usage: credentials.py microvm-id [LCA-credentials.json]")
source = Path(sys.argv[2]) if len(sys.argv) == 3 else Path.home() / ".lca-credentials.json"
root = json.loads(source.read_text())
selected = root.get("providers", {}).get("codex", root)
assert selected.get("access") and selected.get("accountId"), "Codex credentials required"
temporary = {key: selected[key] for key in
             ("access", "accountId", "expires", "expiresAt", "expiresAtMs") if key in selected}
temporary["provider"] = "codex"
vm = aws("get-microvm", "--microvm-identifier", sys.argv[1])
token = aws("create-microvm-shell-auth-token", "--microvm-identifier", sys.argv[1],
            "--expiration-in-minutes", "5")["authToken"]["X-aws-proxy-auth"]
with connect("wss://" + vm["endpoint"] + "/shell", subprotocols=[
        "lambda-microvms.authentication." + token, "lambda-microvms",
        "lambda-microvms.port.8022"], compression=None) as ws:
    ws.send(b"export HISTFILE=/dev/null; set +o history; stty -echo; printf '\\nLCA_READY\\n'\r")
    wait_for(ws, b"\r\nLCA_READY\r\n")
    # Only send secret bytes after the echo/history-off acknowledgement.
    encoded = base64.b64encode(json.dumps(temporary).encode())
    ws.send(b"umask 077; printf '%s' '" + encoded +
            b"' | base64 -d > /tmp/lca-model-credentials.json && chmod 600 /tmp/lca-model-credentials.json && printf '\\nLCA_DONE\\n'\r")
    wait_for(ws, b"\r\nLCA_DONE\r\n")
    ws.send(b"exit\r")
print("Transferred access-only credentials to /tmp/lca-model-credentials.json; remove before termination.")
