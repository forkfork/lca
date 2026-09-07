# Project index source visibility

Observed in `/tmp/lca/logs/lca-20260907-104615-194227.log` and
`/tmp/lca/logs/lca-20260907-104630-194589.log`, with raw requests and tool
results retained in their `.jsonl` companions. The user asked “what things do
we show in the middle of the river when doing tasks?” Both sessions issued
`grep {path="src", pattern="river", glob="*.lua"}` as their first tool call.
The directory does not exist. Both sessions were cancelled during the second
model request; this is repeated initial guessing across sessions, not evidence
of an in-session retry loop. The native arguments and executed path agree.

The latter request's project index contained 200 alphabetically selected files:
186 under evals and none under lua/agent. Nested fixture src directories were
visible, but the implementation was absent. This is a concrete context coverage
defect; attributing the model's choice specifically to those fixtures remains
an inference.

Change: sort inventory paths by depth, then lexically, before applying the
existing 200-file cap. Preserve both inventory backends and the file budget.
The checkout's resulting index contains 24 lua/agent paths, including tui.lua.
No repository-specific paths or fallback search scopes are hardcoded.

Offline acceptance: a fixture with 210 nested eval source files must retain the
main Lua implementation in both Git (tracked fixtures, untracked implementation)
and non-Git inventories, stay at 200 files, and produce deterministic output.
Run tests/test_project_index.lua, make local, and make test.

Decision: adopt the deterministic index coverage fix. Further validation is
required for the hypothesis that this reduces invalid initial searches. No live
campaign was run and no model behavior, latency, token, or cost improvement is
claimed. Any such comparison must register a screen under evals/EXPERIMENTS.md
before live runs. Shallow ordering still cannot guarantee coverage of every
source directory in a large repository, and a model can still guess a bad path.
