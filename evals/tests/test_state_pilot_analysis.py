import sys
import json
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from analyze_state_pilot import audit_state_only, repeated_read_candidates
from regrade_state_pilot import reviewed_result


class StatePilotAnalysisTests(unittest.TestCase):
    def test_regrading_never_promotes_a_protocol_failure(self):
        original = {"passed": False, "score": 0, "metrics": {"cost": 12}}
        grade = {"passed": True, "score": 100}
        result = reviewed_result(original, {"ok": False}, grade, "hash")
        self.assertFalse(result["passed"])
        self.assertTrue(result["grading_review"]["artifact_passed"])
        self.assertEqual(result["metrics"], original["metrics"])

    def test_regrading_can_correct_an_external_grader_false_negative(self):
        original = {"passed": False, "score": 85}
        result = reviewed_result(original, {"ok": True}, {"passed": True, "score": 100}, "hash")
        self.assertTrue(result["passed"])
        self.assertEqual(result["score"], 100)
        self.assertFalse(original["passed"])

    def test_audit_detects_old_context_and_reasoning_leaks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def save(name, value):
                (root / name).write_text(json.dumps(value))
            task = {"role": "user", "text": "task"}
            save("initial-context.json", [task, {"role": "assistant", "text": "old"}])
            save("request-0001.json", {"messages": [task]})
            save("response-0001.json", {"text": '<agent_state>{"goal":"task"}</agent_state>'})
            call = {"type": "function_call", "call_id": "c1", "name": "read", "arguments": "{}"}
            reasoning = {"type": "reasoning", "encrypted_content": "old"}
            output = {"role": "user", "tool_name": "read", "native_call_id": "c1", "text": "evidence"}
            save("observation-0001.json", [{"role": "assistant", "provider_items": [reasoning, call]}, output])
            messages = [task, {"role": "user", "text": 'Current explicit state:\n{"goal":"task"}', "_explicit_state": True},
                        {"role": "assistant", "text": "", "provider_items": [call]}, output,
                        {"role": "user", "text": "Latest observation evidence: " + str(root / "observation-0001.json"), "_explicit_state": True}]
            save("request-0002.json", {"messages": messages})
            self.assertEqual(audit_state_only(root), [])
            messages[2]["provider_items"].append(reasoning)
            save("request-0002.json", {"messages": messages})
            self.assertTrue(any("retained provider" in e for e in audit_state_only(root)))

    def test_only_identical_successful_reads_are_review_candidates(self):
        def event(call, content, error=False):
            return {"name": "read", "call_id": call, "args": {"path": "x"},
                    "result": {"content": content, "is_error": error}}
        self.assertEqual(repeated_read_candidates([
            event("a", "old"), event("b", "new"), event("c", "new", True), event("d", "new")
        ]), [{"path": "x", "first_call": "b", "repeated_call": "d"}])

    def test_different_limits_returning_identical_evidence_still_repeat(self):
        events = [{"name": "read", "call_id": str(limit), "args": {"path": "x", "limit": limit},
                   "result": {"content": "same tagged source"}} for limit in (200, 300)]
        self.assertEqual(len(repeated_read_candidates(events)), 1)


if __name__ == "__main__":
    unittest.main()
