# Legacy edit and experiment cleanup

Removed the unadvertised oldText/newText edit executor and its four private
helpers (matching, replacement, byte-offset line lookup and affected-line count).
The native tool schema already requires tagged editing; the only in-tree
executor callers were two integration tests, now migrated to tagged ranges.
A regression test verifies legacy-only arguments cannot mutate a file.
Tagged edits, atomic multi-hunk edits, stale-tag validation and lint checks remain.

Removed the rejected repository-facts probe/rendering/auditing modules and its
dedicated tests. Removed obsolete lean/minimal prompt transforms, including their
stale text-only tool protocol instructions. Kept the separate pre-harness-quality
comparison because it still has a registered use, rather than treating all eval
code as dead. Simplified prompt auditing and consolidated retired-profile rejection.
Updated eval documentation to stop recommending retired/missing experiments.

Archived exact pre-cleanup code with verified hashes in
research/archive/2026-09-06-legacy-edit-and-prompt-probes.tar.gz. Historical
registrations, reports and results are preserved. Unsupported legacy edit calls
now return a tagged-edit argument error; retired eval profiles fail before input
reading/workspace creation/model calls. There is no hidden alternate executor.

Narrow validation: 15 edit tests, 10 write/edit integration tests and 22 Python
harness tests passed. Full make check passed: local LuaRocks rebuild, full Lua suite, and 105 Python
tests. Output is retained in evals/results/20260906-simplification/make-check.log.
