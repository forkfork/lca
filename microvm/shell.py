#!/usr/bin/env python3
"""Host terminal for AWS's provided shell ingress (requires websockets 15.x)."""
import json
import os
import select
import subprocess
import sys
import termios
import tty

from websockets.exceptions import ConnectionClosedOK
from websockets.sync.client import connect


def aws(*args):
    return json.loads(subprocess.check_output(
        [os.environ.get("AWS_CLI", "aws"), "lambda-microvms", *args,
         "--region", os.environ.get("AWS_REGION", "ap-southeast-2"),
         "--output", "json", "--no-cli-pager"], text=True))


def main():
    if len(sys.argv) != 2 or not sys.stdin.isatty():
        raise SystemExit("Usage (from a terminal): python3 microvm/shell.py microvm-id")
    identifier = sys.argv[1]
    vm = aws("get-microvm", "--microvm-identifier", identifier)
    token = aws("create-microvm-shell-auth-token", "--microvm-identifier",
                identifier, "--expiration-in-minutes", "15")["authToken"]["X-aws-proxy-auth"]
    # Token stays in memory: never a shell argument, file, or printed URL.
    protocols = ["lambda-microvms.authentication." + token,
                 "lambda-microvms", "lambda-microvms.port.8022"]
    with connect("wss://" + vm["endpoint"] + "/shell", subprotocols=protocols,
                 compression=None, max_size=4 * 1024 * 1024) as ws:
        saved = termios.tcgetattr(sys.stdin.fileno())
        try:
            tty.setraw(sys.stdin.fileno())
            while True:
                if select.select([sys.stdin], [], [], 0.02)[0]:
                    data = os.read(sys.stdin.fileno(), 65536)
                    if not data:
                        break
                    ws.send(data)
                try:
                    data = ws.recv(timeout=0)
                except TimeoutError:
                    continue
                if isinstance(data, str):
                    data = data.encode()
                os.write(sys.stdout.fileno(), data)
        except ConnectionClosedOK:
            pass
        finally:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
