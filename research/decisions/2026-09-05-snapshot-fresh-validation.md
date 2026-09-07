# Final bounded validation of snapshot edit recovery

The user approved one final small validation after the conditional Snake result.
The previous fully inspected Snake pair saved one live model call and 42.5% of
continuation time, but the partial-inspection pair saved no calls. Those results
remain unchanged and their controls are not pooled into this study.

## Registration before live calls

Theory `astra_snapshot_fresh_validation`; executable selector
`evals/snapshot_recovery_screen.py plan-validation`, then the frozen `screen.py run`.
Exactly six serial runs: simple baseline/snapshot controls first, then randomized
adjacent baseline/snapshot pairs on two newly authored modules. Seed 929 determines
both task order and within-pair arm order. Explicit Astra/high, normal history,
all tools, identical prompts/schemas and pinned Lua 5.5/module paths in all cells.
The recovery wrapper is byte-for-byte unchanged from the prior screen.

Fresh insertion: an invoice module gains two decimal imports, shifting a later
currency-rounding function by +2 lines. Fresh deletion: a label module loses two
obsolete constants, shifting a later normalization function by -2 lines. Both
fixtures start with actual README/source/test reads, then execute a predetermined
first edit and a second edit with updated coordinates but old tags. These are
constructed recovery boundaries, not naturally sampled failures. Baseline must
reject and treatment must recover. The native history through the second edit
must match exactly across arms. Only its actual result differs.

All fixture descriptors, code, tool implementation, engine roots, grader helpers,
driver, runner and theory are frozen and hashed before calls. Every outgoing
request checks model/effort and normalized instructions/schema parity. Each first
coding request must retain the entire native seed history; audits check the
expected signed offset, replacement, old tags, five closed pairs, and real recovery.

Offline gates: eight exact-byte/native-pair cases cover baseline and treatment,
insertion and deletion, with and without an external source change between edits.
Both externally changed cases must reject without writing. The existing nine
adversarial checks cover interior changes, ambiguous ranges, session isolation,
oversized files and syntax rejection. Independent graders run public/hidden tests,
check protected files and unrelated AST, require obsolete names to be absent, and
require completed post-mutation unittest evidence. Known-good artifacts must pass;
independent rounding/casefold/formatting/scope/verification corruptions must fail.

Budget: six runs maximum, 360 active seconds, 150 seconds per cell, and a $1.50
between-cell standard-equivalent estimated-cost threshold, with a possible one-cell
overshoot. No retries, additional cohorts, or threshold changes after results.
Stop immediately on safety, protocol, activation, task, audit, unknown-usage or
budget failure. Retain every attempted cell and its raw evidence.

Decision gates: all six cells correct; both treatment boundaries recover and both
controls reject; at least one fewer aggregate live coding model call, with neither
task increasing its count; lower coding time on both tasks and at least 10% lower
aggregate coding time; aggregate output tokens increase at most 10%. Fixed seed
execution time is included; historical model generation is excluded identically.
If any efficiency gate fails, park the candidate without extending this campaign.
A pass supports recommending the narrow feature for inclusion, not a claim of
population-wide speed or automatic default promotion from a small screen.

Evidence directory: `evals/results/20260905-snapshot-fresh-validation/`.

## Completed: park; do not include by default

All six live cells passed artifact/evidence grading and request/protocol audits.
Both treatments recovered once, both controls rejected the seeded stale edit,
and the exact native prefix/offset/history checks passed. Frozen engine and
grader hashes matched. No provider retries or missing usage occurred. The eight
fresh offline cases all passed, including both external-change no-write controls;
the prior nine adversarial cases also passed. The full Lua suite and all 112 Python
eval tests passed, and `make local` completed after script changes.

| Task | Arm | Time | Live model calls | Output tokens | Estimated cost |
| --- | --- | ---: | ---: | ---: | ---: |
| Simple | Baseline | 2.374 s | 1 | 5 | $0.040912 |
| Simple | Snapshot | 2.484 s | 1 | 5 | $0.040892 |
| Deletion | Baseline | 14.733 s | 3 | 209 | $0.137662 |
| Deletion | Snapshot | 5.902 s | 2 | 76 | $0.065464 |
| Insertion | Baseline | 14.731 s | 3 | 239 | $0.089392 |
| Insertion | Snapshot | 18.884 s | 4 | 256 | $0.100848 |

Across coding tasks, time fell from 29.464 to 24.786 seconds (15.9%), output tokens
from 448 to 332 (25.9%), and estimated cost from $0.227054 to $0.166312 (26.8%).
But total model calls remained six, insertion gained a call, and insertion time
increased 28.2%. Therefore three required efficiency gates failed: fewer aggregate
calls, no per-task call increase, and lower time on both tasks. Favorable pooled
numbers do not override those preregistered failures.

The trace explains the insertion regression. Both models chose to move Decimal
conversion before the negative-amount check. Baseline incorporated that refinement
in its repair directly from the fresh stale-error source. Treatment had already
applied the seeded body, then read its new tagged source and edited it again before
testing. Automatic recovery removed a failed mutation but did not eliminate the
model's desire to refine the implementation; it introduced a separate read/edit
sequence in this case. Both final artifacts passed the same independent contract.

Decision: stop this experiment line and leave normal editing unchanged. Retain
the eval prototype, adversarial regressions, and raw evidence; do not add a default
feature, permanent experimental setting, or another campaign to seek a favorable
result. This does not show that snapshot recovery is useless or unsafe, only that
the selected narrow optimization failed the final efficiency decision rule.

Six-run cost was $0.475170 standard API equivalent, with 59.521 active runner
seconds. This estimate is not exact service-tier billing. All four screens in this
experiment line total $1.544982 estimated; earlier negative/nonactivated results
remain preserved and are not pooled into the validation controls. Seeded tool
failures live in `boundary.json` and trajectory events; the generic transcript
stale-tag counter does not include these pre-model fixture calls.

## Cleanup after user review

Archived and removed the dedicated eval implementation, scenarios, runners,
tests and registrations from the active tree at user request. See
[archive](../archive/README.md). Original results and decisions are retained.
The experiment never had a production enable flag.
