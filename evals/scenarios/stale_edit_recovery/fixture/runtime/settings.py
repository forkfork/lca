SETTINGS = {
    "connect_timeout_seconds": 10,
    "request_timeout_seconds": 30,
    "shutdown_timeout_seconds": 15,
}


def timeout_for(operation: str) -> int:
    key = f"{operation}_timeout_seconds"
    try:
        return SETTINGS[key]
    except KeyError:
        raise ValueError(f"unknown operation: {operation}") from None
