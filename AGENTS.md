# Agent Notes

- After changing Lua source, scripts, bins, or rockspecs, run `make local` so the local LuaRocks install matches the checkout.
- For behavior changes, run the narrow relevant test first, then `make test` when the change touches shared code.
- Use `make check` when you want both the local LuaRocks install and the full Lua test suite.
- LCA run logs are written under `/tmp/lca/logs`. When debugging a bad UI/tool run, start with the matching timestamped `lca-*.log`, inspect the raw assistant/tool protocol around the failure, and replay parser edge cases from that captured text when possible.

## Hypothesis experiments

- Default exploration to small `study_kind: screen` matrices (4–6 total runs: two arms × two or three scenarios, one run per cell), not full repeated campaigns. Screens can reject an implementation or justify another experiment, never promote a default. Use fresh broader validation for promising candidates; reserve long cohorts for architecture claims and promotion decisions. Keep cheap offline correctness and activation checks.

- Start from an observed river signal, inspect `/river` and the matching raw log, then follow the recipe in `evals/EXPERIMENTS.md`. Repeated arguments or failed tests are observations, not proof of wasted work.
- Follow `evals/EXPERIMENTS.md`. Register the mechanism, executable intervention, controls, budget, and decision rule before live runs.
- Pin model, reasoning, prompt, fixtures, and engine revision/content hashes. Change one causal factor per comparison; do not silently migrate historical theories or cheaper delegate models.
- Before a campaign, test graders on known-good and known-bad artifacts, then smoke-test that each intervention actually activates and satisfies its protocol. Stop an invalid treatment before scaling it.
- Grade task outcomes independently of assistant claims. Report protocol failures separately from artifact correctness; retain failed-run tokens, cost, and time.
- Preserve raw requests, responses, observations, original grades, and run configuration outside the task workspace. Regrade all affected cells symmetrically; never overwrite original evidence.
- A short pilot can reject an implementation, not establish a long-task architectural claim. Record decisions and limitations in `research/decisions/`.

- Report artifact correctness alongside tool calls, model calls, elapsed time, tokens, and estimated cost. Declare the primary metric before running; fewer calls do not count as an improvement if necessary work was skipped.
- End with a recorded drop, further-validation, or adoption decision. Remove rejected runtime code and experimental flags; preserve frozen implementations and evidence outside active runtime paths.
