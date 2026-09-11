# Operational facts after incomplete compaction

## Decision

Further validation is required before claiming a correctness or efficiency
improvement. This screen is complete; do not expand it or treat it as adoption
evidence. Both arms passed every task. The information reached the model and was
explicitly used in one treatment response, but the small tasks did not expose a
correctness failure in the controls. No production change is justified by this
screen alone, and no additional paid validation was launched.

## Registered comparison

[Theory](../../evals/theories/compaction_obligations_screen.json), seed 91107,
Astra/high, identical current prompt and local tools, normal continuation history.
The only treatment difference is visibility of the operational record. The
ablation lives in the eval driver, not a production flag.

Six serial cells: two arms on a simple arithmetic control, stale passing
verification, and unresolved failure followed by unrelated success. Maximum six
launches, $3 between-run standard-equivalent threshold, 480 active seconds,
120-second coding-task timeout. Stop on task/activation failure; no retries.

For each coding cell, setup executes actual tool operations. The stale-pass setup
runs the correct fixture's tests, then writes a broken implementation. The
unresolved-failure setup writes that implementation, runs failing tests, then
runs a successful syntax check. Both use real compaction with an eval-supplied
fixed summary that omits the relevant distinction: “A check passed.” The summary,
task, and broken source are identical within each pair. This is a deliberate
information-loss simulation, not measurement of naturally generated summaries.

Historical motivation: the earlier state-only pilot's archived states 6, 8 and 9
in `evals/results/20260905T044052Z-ambiguous_bug_investigation-state_only-2` show
verified completion downgraded and then lost after reads. That motivates retaining
execution facts; it does not establish the new stale-pass failure's frequency.

## Validation and results

Offline checks exercised real setup executions, forced compaction, identical
summaries, and absence/presence of state. Known-good/bad grader checks reject
broken code, modified tests, missing verification, fake printed verification,
and a successful receipt for a different source hash. The full project suite
and campaign Python preflight passed.

Each coding artifact independently passes behavioral probes, preserves protected
files, and has a successful documented unittest receipt whose recorded source
hash matches the submitted file. Claims in the assistant's final answer are not
used as proof. Actual serialized request audits passed in all six cells. A paired
audit confirmed identical initial messages after removing the treatment record,
identical summaries, and system prompts equal after normalizing workspace paths.

| Task | Arm | Correct / verified | Seconds | Model calls | Tools | Input tokens | Output tokens | Cached tokens | Estimated cost |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| simple | without state | pass | 2.601 | 1 | 0 | 2,990 | 5 | 0 | $0.030150 |
| simple | with state | pass | 2.087 | 1 | 0 | 2,991 | 5 | 0 | $0.030160 |
| unresolved failure | without state | pass | 13.320 | 4 | 6 | 14,410 | 327 | 9,984 | $0.070594 |
| unresolved failure | with state | pass | 13.372 | 4 | 5 | 18,245 | 276 | 5,632 | $0.145562 |
| stale pass | without state | pass | 22.735 | 4 | 7 | 19,654 | 368 | 13,440 | $0.093980 |
| stale pass | with state | pass | 13.853 | 4 | 6 | 15,564 | 298 | 8,448 | $0.094508 |

All-attempt estimated cost: **$0.464954**. Campaign active worker time:
**68.784 seconds**. No failed, retried, timed-out, or missing-usage cells. Prices
are the runner's frozen standard-API equivalents, excluding service-tier effects;
they are not a statement of subscription billing. Setup makes no model calls.

Paired treatment-minus-control differences:

- Unresolved failure: same correctness and four model calls; one fewer tool,
  +0.052 seconds, +3,835 input tokens, +$0.074968 estimated cost.
- Stale pass: same correctness and four model calls; one fewer tool,
  -8.882 seconds, -4,090 input tokens, +$0.000528 estimated cost.
- Simple control: no tools, one model call in both; -0.514 seconds and one extra
  input token. No operational context is injected when there is no state.

The unresolved-failure treatment explicitly noticed that the recorded success
was syntax-only while tax tests had failed. It fixed the sign error and verified
the result. The control also found and fixed the error from source and README.
The stale-pass control did an additional Git-status inspection in a non-Git
fixture; the treatment did not. These are observed trace differences, not proof
of repeatable savings. Different cache hit counts materially affect costs.

## Limits and next distinct test

One run per cell cannot establish a latency/cost distribution. Both tasks are
small and the source defect is obvious. They show useful information consumption
but not that the record is necessary for successful completion.

A subsequent registration should use a less obvious unfinished obligation,
naturally generated summaries, and a read-only-after-pass counter-case to detect
unnecessary re-verification. User constraints present only in prose, active-job
completion, and repeated natural compaction are not evaluated here. Keep the
information ablation separate from changing summarizer instructions or evicting
additional history.

## Preserved evidence

[Campaign directory](../../evals/results/20260911-compaction-obligations-screen/)
contains the immutable manifest and state, frozen `source.tar.gz`, preflight log,
per-cell seeds, exact provider requests/responses, raw transport logs, original
grades, and final workspaces. Derived tables are `screen-results.json` and
`paired-analysis.json`; original evidence was not overwritten.

Frozen source SHA-256:
`d28ffb0d0299ad169db2c44bb464ca10c88c7495e4ef33414265da4103ce0b26`.
