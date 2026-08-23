from __future__ import annotations

import socket

from .ports import configured_port


def main() -> int:
    requested = configured_port()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", requested))
            actual = listener.getsockname()[1]
            listener.listen()
            print(f"service probe passed on port {actual}")
            return 0
    except OSError as exc:
        print(f"startup failed: {exc} on port {requested}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
