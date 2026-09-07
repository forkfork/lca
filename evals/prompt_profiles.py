"""Independent activation audit for supported eval prompt profiles."""
import json

PROFILES = {"current"}


def apply(full, profile):
    if profile not in PROFILES:
        raise ValueError("unsupported audited prompt profile")
    return full


def audit(directory, profile, requests, trajectory):
    snapshot = json.loads((directory / "prompt-profile.json").read_text())
    if snapshot["profile"] != profile or trajectory.get("system_prompt_profile") != profile:
        raise ValueError("prompt profile activation mismatch")
    expected = apply(snapshot["baseline"], profile)
    if snapshot["effective"] != expected:
        raise ValueError("prompt snapshot mismatch")
    for request in requests:
        if json.loads(request.read_text()).get("system_prompt") != expected:
            raise ValueError("outgoing prompt activation mismatch")
