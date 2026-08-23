DEFAULT_REQUEST_TIMEOUT = 30


def request_timeout(override=None):
    if override is None:
        return DEFAULT_REQUEST_TIMEOUT
    if not isinstance(override, int) or isinstance(override, bool) or override <= 0:
        raise ValueError("timeout must be a positive integer")
    return override


RETRY_POLICY = {
    "connect": (1, 2, 4),
    "request": (2, 5, 10),
    "background": (5, 15, 30),
}


FEATURE_POLICY = {
    "audit_events": True,
    "regional_failover": True,
    "legacy_aliases": False,
}


def retry_delays(kind):
    try:
        return RETRY_POLICY[kind]
    except KeyError as exc:
        raise ValueError(f"unknown retry kind: {kind}") from exc


def feature_enabled(name):
    return FEATURE_POLICY.get(name, False)


REGION_ALIASES = {
    "US-EAST": "US-EAST-1",
    "US-WEST": "US-WEST-2",
    "EU": "EU-WEST-1",
}


def normalize_region(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("region must be a non-empty string")
    return value.strip()


def canonical_region(value):
    normalized = normalize_region(value)
    return REGION_ALIASES.get(normalized, normalized)


DEFAULT_HEADERS = {
    "accept": "application/json",
    "user-agent": "lca-runtime/1",
    "x-client-mode": "bounded",
}


def request_headers(extra=None):
    headers = dict(DEFAULT_HEADERS)
    if extra:
        headers.update(extra)
    return headers


SERVICE_PORTS = {
    "api": 443,
    "metrics": 9090,
    "health": 8080,
}


def service_port(name):
    try:
        return SERVICE_PORTS[name]
    except KeyError as exc:
        raise ValueError(f"unknown service: {name}") from exc


def endpoint_url(host, port=None):
    if not isinstance(host, str) or not host.strip():
        raise ValueError("host must be a non-empty string")
    selected_port = SERVICE_PORTS["api"] if port is None else port
    return f"http://{host.strip()}:{selected_port}"
