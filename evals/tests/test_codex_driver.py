from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals"))

import codex_driver  # noqa: E402


class CodexDriverTests(unittest.TestCase):
    def test_normalizes_action_lifecycle_and_usage(self):
        events, usage, messages = codex_driver.normalize_events([
            {"type": "item.started", "item": {
                "id": "cmd_1", "type": "command_execution", "command": "python3 -m unittest",
                "status": "in_progress", "exit_code": None,
            }},
            {"type": "item.completed", "item": {
                "id": "cmd_1", "type": "command_execution", "command": "python3 -m unittest",
                "aggregated_output": "OK", "status": "completed", "exit_code": 0,
            }},
            {"type": "item.completed", "item": {
                "id": "patch_1", "type": "file_change", "status": "completed",
                "changes": [{"path": "app.py", "kind": "add"}],
            }},
            {"type": "item.completed", "item": {"id": "msg_1", "type": "agent_message", "text": "Done"}},
            {"type": "turn.completed", "usage": {
                "input_tokens": 100, "cached_input_tokens": 64,
                "cache_write_input_tokens": 0, "output_tokens": 20,
            }},
        ])
        self.assertEqual([event["phase"] for event in events], ["start", "result", "result"])
        self.assertEqual([event["name"] for event in events], ["command_execution", "command_execution", "file_change"])
        self.assertFalse(events[1]["result"]["is_error"])
        self.assertEqual(events[1]["result"]["content"], "OK")
        self.assertEqual(usage[0]["cached_tokens"], 64)
        self.assertEqual(messages, 1)


if __name__ == "__main__":
    unittest.main()
