"""Promote every tested behavioral contract to a hard gate, not a soft score."""
REQUIRED_CHECKS = (
    "app_exists", "server_starts", "register", "duplicate_rejected", "second_user",
    "wrong_password_rejected", "unknown_user_rejected", "generic_login_failure",
    "malformed_json_rejected", "content_type_enforced", "login", "me", "logout",
    "logout_invalidates", "input_validation", "bounded_input", "durable_user_store",
    "fresh_session_works", "session_expires", "login_rate_limited",
    "no_plaintext_password", "no_plaintext_token", "passwords_are_derived",
    "password_hashes_are_salted",
)


def strict_grade(original, verified, readme_unchanged):
    checks = original.get("evidence", {}).get("checks", {})
    gates = {name: checks.get(name) is True for name in REQUIRED_CHECKS}
    gates.update(final_verification=bool(verified), readme_unchanged=bool(readme_unchanged),
                 no_unrelated_infrastructure=not original.get("evidence", {}).get("forbidden_artifacts"))
    return {**original, "legacy_passed": original.get("passed", False),
            "legacy_hard_gates": original.get("hard_gates", {}),
            "hard_gates": gates, "passed": all(gates.values())}
