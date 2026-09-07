"""Import one real pilot observation; does not manufacture validation/promotion."""
import argparse
import json
from pathlib import Path
from exploration import Ledger, evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pilot_result", type=Path)
    parser.add_argument("ledger", type=Path)
    args = parser.parse_args()
    source = args.pilot_result
    before = json.loads((source / "state-0006.json").read_text())
    after = json.loads((source / "state-0009.json").read_text())
    reviewed = json.loads((source / "result-reviewed.json").read_text())
    files = [source / f"observation-{index:04d}.json" for index in (7, 8, 9)]
    observations = [json.loads(path.read_text()) for path in files]
    tools = [message.get("tool_name") for batch in observations for message in batch if message.get("tool_name")]
    assert tools and set(tools) == {"read"}, tools
    Ledger(args.ledger).append("observation", {
        "id": "verification-record-loss", "task_id": reviewed["scenario"], "family": "coding-verification-state",
        "question": "What changed between the verification records in this attempt?",
        "hypothesis": "Repeated state rewriting can discard completed verification facts even without code changes.",
        "intervention": "After every tool batch, replace accumulated history with model-written state and the latest observation.",
        "observation": {"verification_records_before": len(before["verification"]), "verification_records_after": len(after["verification"]),
            "intervening_tools": tools, "total_tool_calls": reviewed["metrics"]["tool_calls"],
            "total_model_calls": reviewed["metrics"]["llm_calls"], "artifact_passed": reviewed["grading_review"]["artifact_passed"],
            "end_to_end_passed": reviewed["passed"]},
        "judgment": "Observed verification fact loss; causal impact on later tool usage needs a controlled test.",
        "confidence": 0.8,
        "evidence": [evidence(path) for path in [source / "state-0006.json", source / "state-0009.json", source / "result-reviewed.json", *files]],
    })


if __name__ == "__main__":
    main()
