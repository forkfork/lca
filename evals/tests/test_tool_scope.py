import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tool_scope import audit


class ToolScopeTests(unittest.TestCase):
    def test_exact_activation_and_corrupt_payloads(self):
        native = {"type": "function", "name": "read", "parameters": {"type": "object"}}
        baseline = [native, {"type": "web_search"}]
        for scope in ("all", "local_only"):
            with self.subTest(scope=scope), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                def save(name, data):
                    (root / name).write_text(json.dumps(data))
                save("tool-scope-baseline.json", {"tools": baseline})
                save("request-0001.json", {"tool_scope": scope, "model": "gpt-6-astra", "system_prompt": "fixed", "reasoning_effort": "high"})
                body = {"model": "gpt-6-astra", "instructions": "fixed", "reasoning": {"effort": "high"},
                        "tools": baseline if scope == "all" else [native], "tool_choice": "auto", "parallel_tool_calls": True}
                save("provider-request-0001.json", body)
                requests = [root / "request-0001.json"]
                trajectory = {"tool_scope": scope}
                audit(root, scope, requests, trajectory)
                for field, value in (("tools", []), ("model", "wrong"), ("instructions", "changed"),
                                     ("reasoning", {"effort": "low"}), ("parallel_tool_calls", False)):
                    bad = copy.deepcopy(body); bad[field] = value
                    save("provider-request-0001.json", bad)
                    with self.assertRaises(ValueError): audit(root, scope, requests, trajectory)
                (root / "provider-request-0001.json").unlink()
                with self.assertRaisesRegex(ValueError, "missing serialized"): audit(root, scope, requests, trajectory)

    def test_campaign_rejects_unsupported_scopes(self):
        from test_campaign import CampaignTests, THEORY
        helper = CampaignTests()
        for scope in ("all", "local_only", "web_only", "none", "typo"):
            theory = copy.deepcopy(THEORY)
            theory["variants"][0]["tool_scope"] = scope
            if scope in {"all", "local_only"}: helper.manifest(theory=theory)
            else:
                with self.assertRaises(ValueError): helper.manifest(theory=theory)
