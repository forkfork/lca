# Static prompt reduction: local trial

Decision: further validation. The user explicitly requested trying the three investigated reductions. This is a combined local trial, not a controlled causal experiment or evidence-backed performance promotion. No live model campaign was run.

## Changes

- Move experiment invariants from AGENTS.md into evals/EXPERIMENTS.md; keep a mandatory pre-experiment read instruction in AGENTS.md.
- Replace the deep 200-file startup listing with a deterministic root file/directory map, bounded to 200 entries. Preserve key-file summaries and direct deeper discovery to find/grep.
- Conservatively consolidate context-management and action-evidence guidance. Retain verification and tagged-edit safeguards.
- Increment the saved prompt version to 28. Leave tool schemas, cache keys, and session prompt freezing unchanged. Existing running processes keep their current prompt; restarted sessions rebuild outdated saved prompts once.

## Evidence

Baseline: first `test` request in /tmp/lca/logs/lca-20260907-111555-241512.log.jsonl (21,340 instruction characters, 21,357 bytes; server input total 9,998 tokens).

Local generated prompt: /tmp/lca-prompt-trial.txt (12,695 instruction characters, 12,709 bytes). Reduction: 8,645 characters / 40.5%. These are instruction-text measurements, not token savings or full-request measurements.

Passed: focused project-index git/non-git crowded-tree test; all 23 session tests including frozen prompt and save/resume stability; prompt checks for mandatory experiment read and retained Makefile summary; make local; make test (Lua suite and 105 Python tests); git diff --check. Full test output: /tmp/lca-prompt-trial-tests.log.

The working tree contains unrelated changes; these checks validate the current combined checkout, not an isolated commit.

## Limits and next decision

No provider cache-hit, live discovery-cost, experiment-read compliance, task correctness, token-cost, or latency comparison was performed. Static session equality proves only local prompt stability, not provider caching. A prompt-version change may require warming a new prefix.

Observe the local trial before claiming improvement. Any formal follow-up must register separate one-factor comparisons under evals/EXPERIMENTS.md, with independent task grading and complete failed-run accounting. Compare whole-task correctness, uncached input, output, elapsed time, cost, and added discovery calls. Do not attribute the combined reduction to a single behavioral mechanism or promote based on character count alone.
