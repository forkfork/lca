from __future__ import annotations

import socketserver
import sys


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        self.request.sendall(b"unrelated-owner\n")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


with Server(("127.0.0.1", int(sys.argv[1])), Handler) as server:
    server.serve_forever()
