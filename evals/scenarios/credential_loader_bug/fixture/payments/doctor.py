from __future__ import annotations

from .config import api_key, endpoint


def main() -> int:
    if not api_key():
        print("authentication unavailable: application has no payment API key")
        return 2
    print(f"payment configuration available for {endpoint()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
