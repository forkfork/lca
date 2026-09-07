import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "evals"))
import prompt_profiles
import test_campaign


class PromptProfileTests(unittest.TestCase):
    def test_current_preserves_prompt_and_retired_profiles_fail(self):
        self.assertEqual(prompt_profiles.apply("fixed prompt", "current"), "fixed prompt")
        for profile in ("workflow-lite", "planning-clarity", "repo-facts", "lean", "minimal", "unknown"):
            with self.assertRaises(ValueError):
                prompt_profiles.apply("fixed prompt", profile)

    def test_campaign_audits_every_outgoing_prompt(self):
        import campaign
        helper = test_campaign.CampaignTests()
        baseline = "fixed prompt\nprotected\n"
        for profile in ("current",):
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                cell = helper.manifest()["cells"][0]
                cell["variant"]["system_prompt_profile"] = profile
                helper.evidence(directory, cell)
                effective = prompt_profiles.apply(baseline, profile)
                campaign.save(directory / "prompt-profile.json", {"profile": profile, "baseline": baseline, "effective": effective})
                trajectory = campaign.read(directory / "trajectory.json")
                trajectory["system_prompt_profile"] = profile
                campaign.save(directory / "trajectory.json", trajectory)
                request = campaign.read(directory / "request-0001.json")
                request["system_prompt"] = effective
                campaign.save(directory / "request-0001.json", request)
                self.assertTrue(campaign.inspect_result(directory, cell)["passed"])
                request["system_prompt"] += "unexpected instruction"
                campaign.save(directory / "request-0001.json", request)
                with self.assertRaisesRegex(ValueError, "prompt activation"):
                    campaign.inspect_result(directory, cell)


if __name__ == "__main__":
    unittest.main()
