# Obligation discrimination after normal compaction

## Decision

The current derived status logic failed this diagnostic. Do not expand this
screen or treat the operational ledger as validated. Preserve observed outcomes;
reconsider the blanket `run` revision advancement and exact-argument failure
resolution before broader validation. This is a result about this implementation
on a short synthetic history, not a rejection of preserving unfinished work.
No production defaults were changed by this experiment.

The registered stop rule halted after five of six continuation cells. The Ready
ledger arm repeated already valid verification. Its receipt counterpart was not
launched; this experiment therefore cannot establish that receipts would have
avoided that repetition. The completed Pending pair showed no correctness gain
from the ledger and higher continuation cost and latency in this single sample.

## Registered comparison

[Theory](../../evals/theories/obligation_discrimination_screen.json), seed 91109:
Astra/high, current prompt, normal context, local tools; two arms on simple_prompt,
Pending and Ready. Six continuation launches maximum, at most two shared summary
calls, $3 between-run standard-equivalent threshold, 480 active seconds, 150
seconds per coding worker. Stop on any task, discrimination, protocol, activation,
usage or budget failure; no retries or expansion.

Both correct checkouts received real seeded tool calls: inspect source/tests,
`check` fails, optionally `check` succeeds with a changed timeout, then AST parsing
succeeds without changing files. The first arm in each randomized pair generated
one ordinary production summary from the full history and operational record.
The other arm reused that exact summary. No summary was rewritten or selected.

The continuation factor was the appended view: current production operational
record versus the last 24 ordered command arguments/results, without derived
classifications. This compares complete retention/rendering mechanisms, including
output retention differences, rather than isolating a single wording change.
No artificial delays were added to inflate the cost of a repeated test.

## Results

Continuation metrics exclude shared summary generation symmetrically. All-attempt
accounting below includes it. Tool counts include read operations, not only shells.

| Task | Arm | Discrimination | Seconds | Model calls | Tools | Input tokens | Cached | Output | Estimated continuation cost |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| Simple | ledger | pass | 2.293 | 1 | 0 | 2,991 | 0 | 5 | $0.030160 |
| Simple | receipts | pass | 2.699 | 1 | 0 | 2,989 | 0 | 5 | $0.030140 |
| Pending | receipts | pass | 11.607 | 2 | 3 | 9,793 | 2,816 | 382 | $0.091686 |
| Pending | ledger | pass | 14.477 | 3 | 7 | 16,230 | 5,632 | 477 | $0.135462 |
| Ready | ledger | fail: repeated check | 6.937 | 2 | 1 | 9,446 | 2,816 | 191 | $0.078666 |
| Ready | receipts | not launched | — | — | — | — | — | — | — |

All five completed artifacts were correct; coding fixtures remained unchanged.
Pending obtained one successful continuation check in each arm. Ready's external
check log contains exits `[1, 0, 0]`: failure, pre-compaction pass, redundant
continuation pass. File hashes were identical at every check start and finish.
The Ready failure is unnecessary work, not broken code or skipped verification.

The Pending ledger continuation used one additional model call, four additional
tools, 6,437 additional input tokens, 2.870 additional seconds, and $0.043776 more.
These are one-pair observations, not stable performance estimates.

Shared summary generation cost $0.140404. All attempted calls cost an estimated
$0.506518, with 66.109 active worker seconds including setup and grading. There
were nine continuation model calls plus two summary calls. All usage was present;
no transport or activation failures, retries, or excluded model attempts occurred.
Cost is the runner's standard API-equivalent estimate, not a subscription bill.

## Mechanism evidence

The Pending summary correctly distinguished failed behavioral verification from
the later syntax pass. Both continuations completed the outstanding check.

In Ready, the generated checkpoint said:

> A subsequent recorded `check` passed all three tests.

It also described the operational record's stale classification and unresolved
exact-retry entry, then instructed:

> Run the documented `check` command to obtain current verification evidence.

The continuation executed `check && python3 ...` and repeated the already valid
check. The summary explicitly incorporated the ledger classification despite
also recording that no edits were shown. This exposes a route by which conservative
bookkeeping becomes a new obligation during compaction. The independent external
log and hashes establish that the successful verification was already current.

This does not isolate whether the appended ledger, shared summary instruction,
or their combination drove repetition. Because the normal summary was generated
with the ledger, the unrun receipts arm would have inherited that instruction too.
That is a limitation of this marginal continuation-view comparison. Do not claim a
receipt victory on Ready or quietly resume the halted matrix. Any fresh comparison
of complete compaction mechanisms must account for the summarizer input as well
as the continuing agent's view.

## Validation and evidence

Local installation and the full Lua suite passed; 116 Python eval tests passed.
New offline checks cover real seed executions, shared checkpoint reuse, actual-view
activation rejection, missing verification, unnecessary repetition, stale evidence
after a real edit, broken source, and summary-cost inclusion. Independent grading
uses an invocation log outside the task workspace, file hashes, and external
behavior probes rather than final-answer claims.

All five actual-request, prompt, tool-scope and usage audits passed again after
collection. The completed pair's initial histories and summary matched exactly.
The engine/source fingerprint remained
`73536fb30fc458b389c8d48e8b68b346ffe2a1948fa999848ad9d12d9e4bb607`.

[Evidence directory](../../evals/results/20260911-obligation-discrimination-screen/)
contains the immutable manifest, frozen `source.tar.gz`, original grades, seeded
histories, external invocation logs, raw summary and continuation requests,
provider payloads, responses, transport traces, retained workspaces, halted state,
and derived `analysis.json`. Original evidence has not been rewritten.
