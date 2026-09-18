# Expanded order cancellation: baseline ready for edit-tool comparisons

Decision: **baseline-ready for a fresh paired edit-tool screen**. All three
independent Astra/high coding attempts passed every gate, as did three simple
controls. Both pilot attempts and the separate smoke run changed ten source
files and used more than twenty tool operations. This satisfies the registered
workload/calibration gate. No alternative editing tool was implemented or tested,
and no comparative speed, cost, or reliability claim is supported.

## Workload version 2

`evals/scenarios/multifile_order_cancellation/fixture` grew from **7 files / 244
lines** to **23 files / 1,173 lines**: 17 application modules (709 lines), five
public test modules (344 lines), and the task contract (120 lines). Size excludes
Python caches. The added code implements actual existing behavior, not padding.

The existing system now includes SQLite transactions/savepoints, append-only
schema migrations, stock reservations, payment authorization/capture, shipping,
returns, event history, outbox delivery, customer/currency reporting, JSON API and
CLI. The requested feature crosses these boundaries: durable single and atomic
batch cancellation, normalized per-order idempotency, stored response snapshots,
version checks, inventory release, payment voiding, audit/outbox effects, migration
from a real old database, and transport/reporting integration.

The starting fixture has 28 passing regression tests and two intentionally failing
feature examples. The agent may add source and new tests but may not alter README
or any existing test. The reference implementation and hidden tests remain outside
the fixture copied to the model. The API here is an in-process transport adapter,
not a deployed network service; the CLI executes in separate processes.

The original version-1 scenario is preserved under the evidence root below, and
in git at `e65ce9d`. A successful historical version-1 trace had 16 tool operations
and four edits across three files; it is preserved as `historical-v1-baseline`.
Do not pool historical results for this scenario ID with fixture version 2.

## Independent correctness and grader checks

The external grader runs the entire public suite and **22 hidden test methods**,
including parameterized invalid-input and fault-injection cases. It verifies:

- Order/version/data preservation; normalized request identity and reason conflicts;
  replay of the original response after reopening and later state changes.
- Correct stock release/payment voiding, unchanged unrelated orders, exactly one
  event/outbox/receipt, receipt key schema and preserved delivery state on retry.
- Rollback at every new write checkpoint and existing mutation checkpoints;
  whole-batch rollback including failure on the second receipt; validation before
  the first write; 1..50-item bounds and input-order results.
- Two independent database connections cancelling concurrently, with one effect
  for matching keys and one winner for conflicting keys.
- Real version-1 schema migration with all preexisting tables/rows preserved;
  stable API/CLI response/error contracts and cancellation-aware currency reports.

The grader preserves scope, migration 1, added tests, and observed full-suite
verification after the final successful edit. It records edit/read behavior but
no longer requires a particular read sequence or particular layer filenames to
be edited as a correctness gate. Workload breadth is a separate calibration gate.

Offline contract tests accept the reference and reject ten broken implementations:
lost single/batch atomicity, global idempotency keys, current-state rather than
saved-response replay, wrong inventory state, missing fault checkpoint, missing
reason conflict, bool-as-version, cancelled revenue and broken CLI. Additional
checks reject scope/migration changes, absent or stale verification, and the
unimplemented fixture; completed durable test jobs are accepted as evidence.

A post-campaign negative test demonstrated that `python -B` still reads existing
bytecode: unchecked cached good code could mask broken source. The grader now
uses a fresh Python cache prefix for each probe. Original grades remain intact.
Every archived artifact passed both fresh-copy regrading with the frozen original
grader and symmetric regrading with the hardened source-only grader. This repair
changed the grader only, not any model-run prompt, fixture or implementation.

## Registered baseline

Theory: `evals/theories/order_cancellation_v2_calibration.json`.
Single arm: current tagged edit, GPT-6 Astra/high, normal context, current prompt,
local tools. Seed 91802. One smoke and two pilot runs per scenario, six cells total.
The initial four-cell plan was rejected offline because calibrations require at
least two pilot repetitions; it launched no model calls. The accepted six-cell
manifest was frozen before any model call, with a $12 between-run estimated-cost
threshold, 3,000 active seconds, and 900 seconds per task. No cells were retried.

Captured provider requests confirm Astra/high and the existing `edit` schema;
`multi_edit` and alternative patch tools were not exposed. Coding traces show
source mutations through tagged edits and new tests through `write`. Shell use
was exclusively the documented full-suite invocation, without shell source edits.

| Stage / cell | Artifact + final verification | Time s | Tool calls | Model calls | Tagged edits | Source files changed | Changed source lines | Added test lines | Estimated USD |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Smoke / cell-0001 | Pass | 173.137 | 33 | 9 | 12 | 10 | 120 | 341 | 0.887574 |
| Pilot / cell-0003 | Pass | 175.532 | 34 | 15 | 13 | 10 | 116 | 306 | 1.152172 |
| Pilot / cell-0004 | Pass | 167.892 | 37 | 9 | 10 | 10 | 123 | 351 | 0.922266 |

Pilot mean task time: 171.712 seconds; pilot mean estimated cost: USD 1.037219.
All three coding attempts had zero failed edit/tool calls. The third ran the
public suite twice, before and after adding tests; the other two ran it once.
These tasks exercised multi-file coordination but did not produce failure/recovery
trajectories. New test lines are reported separately from edits to existing source.

| Cell | Prompt tokens | Cached tokens | Output tokens |
|---|---:|---:|---:|
| cell-0000 | 3116 | 0 | 5 |
| cell-0001 | 144590 | 113664 | 9293 |
| cell-0002 | 3115 | 0 | 5 |
| cell-0003 | 279800 | 228992 | 8302 |
| cell-0004 | 162371 | 127616 | 8942 |
| cell-0005 | 3116 | 0 | 5 |

Three simple controls also passed (2.800, 1.929 and 2.246 seconds; one model call,
zero tools each). Total across all six cells: **USD 3.056232 standard-API-equivalent
estimated cost**, 526.716 active worker seconds. Token estimates use the frozen
runner price table, exclude service-tier/hosted-tool charges and are not an actual
subscription bill. Offline setup, grading tests and analysis are outside that time.

## Validation, evidence and limits

Narrow grader contract tests and the full Python eval suite passed before live
runs. The new bytecode regression and full eval suite were rerun after grader
hardening. `make local` and whitespace checks completed. No shared Lua/runtime
code changed in this task; there is no reason to rerun paid cells for unchanged
model inputs or rerun the Lua suite for fixture-only changes.

Evidence root:
`/home/tim/.local/state/lca/research/order-cancellation-v2-20260918/`.
It contains the original scenario and trace, frozen source/manifest, full campaign
with raw requests/responses, original workspaces/grades, metrics, independent
regrade outputs, grader test logs and the hardened grader with its hash.
Original campaign: `evals/results/order-cancellation-v2-20260918-v1`.
Frozen campaign source SHA256:
`14365c9ecefe3b814bea75c84a183f6aaeda3c2dc0ca0fe252cef95ab7fe5961`.

This is a richer synthetic fixture and a reproducible roughly three-minute
baseline, not a large production repository or a diverse long-task benchmark.
Three successful attempts cannot establish rare-failure rates. Future tool
comparisons should freeze this fixture and use fresh paired runs with identical
model/reasoning, prompt requirements, syntax checks and graders. Extend the
trajectory adapter for the alternative tool's mutation events before comparing;
do not accidentally count its edits as absent verification. Start with a small
registered screen and keep correctness, file changes, calls, time, cache use and
cost together. Do not claim a winner from this baseline alone.
