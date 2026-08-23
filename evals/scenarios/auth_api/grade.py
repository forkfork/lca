from __future__ import annotations

import http.client
import json
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path


workspace = Path(sys.argv[1])
trajectory = json.loads(Path(sys.argv[2]).read_text())
database = workspace / ".hidden-eval.db"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def request(port: int, method: str, path: str, payload=None, token=None, raw_body=None, headers=None):
    headers = dict(headers or {})
    body = raw_body
    if payload is not None:
        body = json.dumps(payload)
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        raw = response.read()
        try:
            decoded = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            decoded = None
        return response.status, decoded, raw.decode("utf-8", "replace")
    finally:
        conn.close()


checks: dict[str, bool] = {}
evidence: dict[str, object] = {}
process = None
port = free_port()
app = workspace / "app.py"
live_token = None

try:
    checks["app_exists"] = app.is_file()
    if checks["app_exists"]:
        process = subprocess.Popen(
            [sys.executable, str(app), "--host", "127.0.0.1", "--port", str(port), "--database", str(database), "--token-ttl-seconds", "2"],
            cwd=workspace,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        for _ in range(50):
            if process.poll() is not None:
                break
            try:
                request(port, "GET", "/me")
                checks["server_starts"] = True
                break
            except (OSError, http.client.HTTPException):
                time.sleep(0.1)
        checks.setdefault("server_starts", False)

    if checks.get("server_starts"):
        first = {"email": "alice@example.com", "password": "correct horse battery staple"}
        second = {"email": "bob@example.com", "password": first["password"]}

        status, body, _ = request(port, "POST", "/register", first)
        checks["register"] = status == 201 and isinstance(body, dict) and "password" not in body
        status, _, _ = request(port, "POST", "/register", first)
        checks["duplicate_rejected"] = status == 409
        status, _, _ = request(port, "POST", "/register", second)
        checks["second_user"] = status == 201
        status, wrong_body, _ = request(port, "POST", "/login", {**first, "password": "wrong password"})
        checks["wrong_password_rejected"] = status == 401
        status, unknown_body, _ = request(port, "POST", "/login", {"email": "nobody@example.com", "password": "wrong password"})
        checks["unknown_user_rejected"] = status == 401
        checks["generic_login_failure"] = wrong_body == unknown_body
        status, _, _ = request(port, "POST", "/login", raw_body="{bad json", headers={"Content-Type": "application/json"})
        checks["malformed_json_rejected"] = status in (400, 422)
        status, _, _ = request(port, "POST", "/login", raw_body=json.dumps(first), headers={"Content-Type": "text/plain"})
        checks["content_type_enforced"] = status in (400, 415)
        status, body, _ = request(port, "POST", "/login", first)
        token = body.get("token") if isinstance(body, dict) else None
        checks["login"] = status == 200 and isinstance(token, str) and len(token) >= 32
        status, body, _ = request(port, "GET", "/me", token=token)
        checks["me"] = status == 200 and isinstance(body, dict) and body.get("email") == first["email"]
        status, _, _ = request(port, "POST", "/logout", token=token)
        checks["logout"] = status in (200, 204)
        status, _, _ = request(port, "GET", "/me", token=token)
        checks["logout_invalidates"] = status == 401
        status, _, _ = request(port, "POST", "/register", {"email": "bad", "password": "short"})
        checks["input_validation"] = status in (400, 422)
        status, _, _ = request(port, "POST", "/register", {"email": "x@example.com", "password": "x" * 20000})
        checks["bounded_input"] = status in (400, 413, 422)

        # A fresh process must be able to authenticate a previously-created user.
        process.terminate()
        first_stdout, first_stderr = process.communicate(timeout=3)
        evidence["first_server_stdout_tail"] = first_stdout[-1000:]
        evidence["first_server_stderr_tail"] = first_stderr[-1000:]
        port = free_port()
        process = subprocess.Popen(
            [sys.executable, str(app), "--host", "127.0.0.1", "--port", str(port), "--database", str(database), "--token-ttl-seconds", "2"],
            cwd=workspace,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        restarted = False
        for _ in range(50):
            if process.poll() is not None:
                break
            try:
                request(port, "GET", "/me")
                restarted = True
                break
            except (OSError, http.client.HTTPException):
                time.sleep(0.1)
        if restarted:
            status, body, _ = request(port, "POST", "/login", first)
            live_token = body.get("token") if isinstance(body, dict) else None
            checks["durable_user_store"] = status == 200 and isinstance(live_token, str)
            if live_token:
                status, _, _ = request(port, "GET", "/me", token=live_token)
                checks["fresh_session_works"] = status == 200
                time.sleep(2.2)
                status, _, _ = request(port, "GET", "/me", token=live_token)
                checks["session_expires"] = status == 401
            else:
                checks["fresh_session_works"] = False
                checks["session_expires"] = False

            rate_statuses = []
            for _ in range(6):
                status, _, _ = request(port, "POST", "/login", {**second, "password": "wrong password"})
                rate_statuses.append(status)
            checks["login_rate_limited"] = 429 in rate_statuses
            evidence["failed_login_statuses"] = rate_statuses
        else:
            checks["durable_user_store"] = False

    if database.exists():
        plaintext = b"correct horse battery staple"
        database_bytes = b"".join(path.read_bytes() for path in workspace.glob(database.name + "*") if path.is_file())
        checks["no_plaintext_password"] = plaintext not in database_bytes
        checks["no_plaintext_token"] = bool(live_token) and live_token.encode() not in database_bytes
        try:
            conn = sqlite3.connect(database)
            password_values = []
            for (table,) in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"):
                if table.startswith("sqlite_"):
                    continue
                quoted_table = table.replace('"', '""')
                columns = list(conn.execute(f'PRAGMA table_info("{quoted_table}")'))
                password_indexes = [index for index, column in enumerate(columns) if "password" in str(column[1]).lower()]
                for row in conn.execute(f'SELECT * FROM "{quoted_table}"'):
                    password_values.extend(str(row[index]) for index in password_indexes if row[index] is not None)
            conn.close()
            checks["passwords_are_derived"] = len(password_values) >= 2 and all(
                len(value) >= 32 and value != "correct horse battery staple" for value in password_values
            )
            checks["password_hashes_are_salted"] = len(set(password_values)) >= 2
        except sqlite3.Error as exc:
            evidence["sqlite_error"] = str(exc)
            checks["passwords_are_derived"] = False
            checks["password_hashes_are_salted"] = False
    else:
        checks["no_plaintext_password"] = False
        checks["passwords_are_derived"] = False
        checks["password_hashes_are_salted"] = False
        checks["no_plaintext_token"] = False
except Exception as exc:
    evidence["grader_runtime_error"] = f"{type(exc).__name__}: {exc}"
finally:
    if process is not None:
        process.terminate()
        try:
            stdout, stderr = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
        evidence["server_stdout_tail"] = stdout[-2000:]
        evidence["server_stderr_tail"] = stderr[-2000:]
    if database.exists():
        database.unlink()

functional_names = ["app_exists", "server_starts", "register", "duplicate_rejected", "second_user", "wrong_password_rejected", "unknown_user_rejected", "login", "me", "logout", "logout_invalidates", "durable_user_store", "fresh_session_works"]
security_names = ["no_plaintext_password", "no_plaintext_token", "passwords_are_derived", "password_hashes_are_salted", "input_validation", "bounded_input", "generic_login_failure", "malformed_json_rejected", "content_type_enforced", "session_expires", "login_rate_limited"]
functional = round(50 * sum(checks.get(name, False) for name in functional_names) / len(functional_names))
security = round(30 * sum(checks.get(name, False) for name in security_names) / len(security_names))

tool_events = [event for event in trajectory.get("events", []) if event.get("result")]
tool_names = [event.get("name") for event in tool_events]
run_commands = [
    str(event.get("args", {}).get("command", "")) for event in tool_events
    if event.get("name") in ("run", "shell", "command_execution")
]
tested = any("test" in command.lower() for command in run_commands)
tool_count = len(tool_events)
errored_tools = sum(1 for event in tool_events if event.get("result", {}).get("is_error"))
verification = 10 if tested and errored_tools == 0 else 7 if tested else 0
forbidden_artifacts = [
    name for name in ("Dockerfile", "docker-compose.yml", "compose.yml", "terraform", "k8s", "nginx.conf")
    if (workspace / name).exists()
]
efficiency = 0 if forbidden_artifacts else 5 if tool_count <= 12 else 3 if tool_count <= 20 else 1 if tool_count <= 30 else 0
final_text = trajectory.get("final", "")
communication = 5 if final_text.strip() and len(final_text) <= 2000 else 2 if final_text.strip() else 0

dimensions = {
    "functional_behavior": functional,
    "security_invariants": security,
    "verification_discipline": verification,
    "trajectory_efficiency": efficiency,
    "final_communication": communication,
}
hard_gates = {
    "core_auth_flow": all(checks.get(name, False) for name in ("register", "login", "me", "logout_invalidates")),
    "password_not_plaintext": checks.get("no_plaintext_password", False),
    "agent_ran_tests": tested,
    "sessions_expire": checks.get("session_expires", False),
    "failed_logins_throttled": checks.get("login_rate_limited", False),
}
evidence.update({"checks": checks, "tool_count": tool_count, "tool_names": tool_names, "run_commands": run_commands, "errored_tools": errored_tools, "forbidden_artifacts": forbidden_artifacts})

print(json.dumps({
    "score": sum(dimensions.values()),
    "passed": all(hard_gates.values()) and sum(dimensions.values()) >= 75,
    "dimensions": dimensions,
    "hard_gates": hard_gates,
    "evidence": evidence,
}))
