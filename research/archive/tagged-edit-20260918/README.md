# Tagged edit archive — 2026-09-18

Preserved before the user-directed switch to the tested V4A patch function:

- `lua/agent/tools/edit.lua`: tagged range editing, multi_edit, bounded relocation,
  stale-tag evidence, and syntax diagnostics.
- `lua/agent/tool_registry.lua`: original schemas and prompt.
- `lua/agent/parallel.lua`: grouping of non-overlapping tagged calls.
- `tests/`: original edit and batch regression suites.
- `evals/`: experiment adapters, request audit, upstream parser and license.

The tagged read/edit design was inspired by Salvatore Sanfilippo (@antirez),
https://antirez.com/news/166. The upstream patch parser retains its MIT license.
These files are research artifacts, not installed runtime modules.

For exact experiment replay use the complete frozen checkout, not these files
overlaid on a newer production tree:
`/home/tim/.local/state/lca/research/openai-patch-fixed-tests-20260918/frozen-source-v1`.
The corresponding campaign, raw requests, outputs, grades and metrics live in
that archive's parent. See `research/decisions/2026-09-18-openai-patch-fixed-tests-screen.md`.
Historical theory profiles are intentionally rejected by the current driver:
rerunning them on the new default would silently change the control arm.
