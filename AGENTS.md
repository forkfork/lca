# Agent Notes

- After changing Lua source, scripts, bins, or rockspecs, run `make local` so the local LuaRocks install matches the checkout.
- For behavior changes, run the narrow relevant test first, then `make test` when the change touches shared code.
- Use `make check` when you want both the local LuaRocks install and the full Lua test suite.
- LCA run logs are written under `/tmp/lca/logs`. When debugging a bad UI/tool run, start with the matching timestamped `lca-*.log`, inspect the raw assistant/tool protocol around the failure, and replay parser edge cases from that captured text when possible.

## Frugal maintenance

- `make local` and `make test` report one line per successful step/suite; failures retain captured diagnostics. Use `VERBOSE=1` for live output, or `make test TESTS=tests/test_tui.lua` for a focused suite.
- Use the injected project map and already-returned evidence before listing files. Search the smallest relevant path; request filenames first when locating code, then bounded source context. Do not repeat overlapping reads of unchanged code.
- For small edits, skip routine progress narration and extra plans; inspect, edit with a regression test, verify, and summarize. Keep relevant tests and failure diagnostics intact.
- Bound output at its source where supported. For noisy verification outside these targets, capture output and show a success summary or failure diagnostics without masking the command's exit status.
## Hypothesis experiments

- Before designing or running any hypothesis experiment, read `evals/EXPERIMENTS.md` and follow its invariants and workflow. This includes registration, small screens, independent grading, evidence preservation, and a recorded decision; a screen never establishes adoption.
