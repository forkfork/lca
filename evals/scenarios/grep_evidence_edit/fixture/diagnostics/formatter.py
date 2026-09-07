"""Stable diagnostic labels consumed by log parsers."""

STATUS_MARKERS = {
    "ok": "request_ok",
    "denied": "request_denied",
    "timeout": "legacy_timeout",
    "unavailable": "service_unavailable",
}


def format_status(status: str, detail: str) -> str:
    """Return the deliberately boring wire representation."""
    marker = STATUS_MARKERS.get(status, "request_unknown")
    return f"{marker}:{detail.strip()}"
