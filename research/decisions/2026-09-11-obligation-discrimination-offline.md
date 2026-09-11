# Discriminating unfinished work from completed work

## Decision

Further validation should compare the current operational record with a simpler
receipt-preservation alternative, on histories that demand different actions
despite identical correct source files. Do not repeat the obvious-bug screen.
This note records an offline diagnostic and a proposed live test, not a completed
model comparison or a decision to adopt either implementation.

## Concrete offline observation

The previous live screen passed in both arms because the source defect could be
rediscovered by inspection. Its evidence and limitations are in
[the screen decision](2026-09-11-compaction-obligations-screen.md).

Using the existing `transient_verification_failure` fixture and its documented
`check` executable, the offline probe executed two histories through the actual
run tool and operational-state observer:

| History | Executed observations | Appropriate continuation |
| --- | --- | --- |
| Pending | Required check fails; source syntax inspection succeeds | Obtain successful required verification before declaring completion |
| Ready | Required check fails; the same check passes with a longer tool timeout; source syntax inspection succeeds | Preserve that verification and finish without repeating it solely because of the inspection |

The fixture intentionally simulates a one-off verification failure. The successful
retry runs the real fixture tests. The final command parses the source with
Python's AST module; it does not edit it. Source hashes before/after and across
both checkouts are identical. No model calls were made.

The actual emitted operational record retains a failure entry in both cases.
In Ready, `check` succeeded with timeout 20000 rather than 10000, so the exact
argument digest does not clear the old failure. The subsequent read-only shell
inspection advances the observed mutation revision, labeling the successful
verification stale. Those behaviours follow the current conservative design;
they do not establish that a model will misinterpret it, since the successful
command receipt is also present.

| History | Full operational context | Plain command receipts, compact JSON |
| --- | ---: | ---: |
| Pending | 2,203 bytes | 526 bytes |
| Ready | 2,506 bytes | 1,076 bytes |

These are UTF-8 byte counts for these exact examples, not token or billing
estimates. The receipt view retains actual command arguments and outputs and
makes no derived stale/unresolved classifications. It is not yet a production
implementation or a validated long-history retention policy.

## Proposed next live screen

Two arms on `simple_prompt`, Pending, and Ready: six launches maximum. Compare
current full operational state with a minimal retained command-receipt buffer.
Keep model/reasoning, instructions, source, tools, and available evidence fixed.
Both arms must receive the same observations; do not advantage the ledger by
deleting the receipts from the alternative or by choosing a buffer that drops
the relevant outcome. Keep the original task/constraints equally available.

Use an ordinarily generated checkpoint, shared within each matched pair, instead
of deliberately selecting a misleading summary. Generate and account for that
checkpoint inside the registered experiment; retain its input/output and use it
unchanged for both continuations. Do not select or rewrite summaries after seeing
whether they help the treatment. If normal compaction already preserves the
distinction, that is evidence against needing additional machinery on this task.

The primary outcome is correct discrimination:

- Pending: the required verification is successfully completed before the task
  is reported complete; no unnecessary code changes or scope violations.
- Ready: valid verification survives inspection; no unnecessary repeat of the
  required check and no invented code repair.

An independent invocation log outside the task workspace records check starts,
completion, and results. Source hashes establish whether verification still
applies. Grade actual actions and final artifacts separately from final claims.
Allow legitimate read-only review in both histories. Validate grader positive
and negative cases, including a pass followed by a real edit, before live work.

Record tool/model calls, input/output/cache tokens, elapsed time, and estimated
cost for every attempt. No artificial sleep should masquerade as measured
integration-test cost; repeated expensive verification is initially a counted
behaviour, with economic validation on a real workload later if warranted.

Pre-register the executable intervention, source/fixture/grader hashes, seed,
budgets, and stopping rules before launching. The existing small-screen budget
of six launches, $3 between-run standard-equivalent threshold, and 480 active
seconds is a reasonable proposed ceiling; this note has not launched that cohort.

## What would justify the complexity?

The full record must distinguish the two histories at least as reliably as raw
receipts and demonstrate an advantage that compensates for its added context and
maintenance. A failure on Ready would expose the cost of false outstanding-work
signals. A tie with cheaper receipts argues for the simpler mechanism on this
workload, not for repeatedly making the test harder until the ledger wins.

Even a positive six-cell screen only justifies fresh validation. User constraints
in prose, active jobs, large histories, and repeated compaction remain separate
claims. This test deliberately targets whether the current derived status logic
adds value over preserving the observations themselves.

## Evidence

[Offline evidence directory](../../evals/results/20260911-obligation-discrimination-offline/)
contains the exact Lua setup text, both raw event histories, current operational
records, receipt views, stderr, and before/after source hashes. `results.json`
summarizes the diagnostic. The original live-screen results remain unchanged.
