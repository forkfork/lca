# Retire rejected runtime experiments and consolidate search

Decision: remove read-only delegation, read-only dependency DAG scheduling, and
automatic fork/join from the active runtime. Their prior decision reports did
not justify promotion; keeping them threaded through sessions, prompts, native
schemas, and execution adds maintenance cost. This does not reject every future
implementation of these ideas.

Removed the standalone delegate and experiment-only tests, scheduling branches,
flag propagation and prompt-cache fields, two unused protocol exports, and the
obsolete XML exact-edit eval prompt transform. The historical XML parser still
used by compaction remains. Normal asynchronous shell batching, mutation guards,
read budgets, tagged edits, and multi-edit support remain.

The snapshot and recovery instructions are in `research/archive/README.md`.
Original experiment manifests, reports, trajectories, and metric readers remain
unchanged. Selected retired eval options fail before workspace creation/model
calls. Existing sessions discard retired metadata and rebuild old prompts.

Consolidation also fixed a real default-path defect: batched grep had diverged
from direct grep and still treated dash-prefixed patterns as command options.
Both paths now share command construction and formatting. A failing-then-passing
batch regression covers dash patterns, globs, no matches, invalid regexes, and
tagged evidence. See the grep-dash decision for the original observation.

Packaging audit found three required modules absent from the rockspec:
`source_evidence`, `context_limits`, and `update_plan`. Added all three plus a
module-inventory regression; verified installed modules load outside the checkout
and the retired delegate is no longer installed.

Validation: focused grep/parallel/protocol/session/core/provider tests passed;
`make check` passed the complete Lua suite and 105 Python tests
(`/tmp/lca-cleanup-check.log`). Subsequent packaging/schema regressions passed;
`make local` refreshed the final manifest, and an installed-runtime smoke from
`/tmp` passed (`/tmp/lca-cleanup-install.log` records installation). No paid model
campaign and no claimed end-to-end speed percentage.
