# Exploration ledger: mechanism tested, promotion withheld

Implemented an eval-only append-only record with observation, candidate and
promotion events; validations are evidence attached to a candidate, not global
instructions. Confidence never authorizes promotion. Rules and the validation/
held-out task split are fixed before validation evidence is submitted.

## What was tested

Local install and the full Lua suite passed; the final Python suite contains
80 passing tests, including promotion gates and all four experience-arm audits.

Synthetic unit tests exercise the user's five effects (+21%, +18%, +2%, -4%,
+16%). They produce a conditional promotion under a predeclared median-gain
threshold of 10% and maximum regression of 5%. Tests also reject missing tasks,
duplicate validations, correctness failures, excessive regressions, changed
evidence and reused evaluation tasks. These numbers are test fixtures, not
measured LCA results or proof that AST caching is beneficial.

A real record was imported from
`20260905T044052Z-ambiguous_bug_investigation-state_only-2`: verification count
fell from one at state 6 to zero at state 9, with seven intervening reads. The
full run made 41 tool calls and 17 model calls. The final artifact passed the
external grader, but the run failed its state-emission protocol. Captured source
artifacts are embedded and hashed in the ledger. That distinction remains in
the source evidence; the blind view intentionally provides fewer details.

## Independent interpretation check

One fresh Astra/high LCA invocation, empty workspace, no tools, no original
hypothesis/judgment/confidence, and no source artifact paths or evidence bodies.
The predeclared manual rubric was: identify the record loss, keep any lesson
conditional, and ask for cross-task validation. The response met all three.
It also proposed competing explanations (logging/visibility, stale evidence,
and unrelated failure causes), and did not claim a causal link to task failure.

Result: independent agreement about a candidate mechanism, **not promotion**.
The reviewer was the same model family and received selected observations and
a request for conditional interpretation, so agreement is weak triangulation.
The check cost $0.04278 standard-API-equivalent, took 10.657 seconds, used one
model call and zero tools. Evidence is in
`evals/results/20260905-exploration-blind-review/`; the real ledger is in
`evals/results/20260905-exploration-ledger/`.

## What remains deliberately unproven

The conditional verification candidate is registered in
`evals/verification_candidate.json`. Five new paired validation tasks are needed;
old pilot outcomes must not be retrofitted as post-registration validation.
The original ambiguous-bug discovery task is excluded from held-out evaluation.
No candidate has been promoted on real evidence and no A/B/C/D benefit claim is
made. The four-arm theory refuses to run without a real, matched frozen corpus
and at least one promoted lesson. D versus C remains the primary comparison.

This first implementation validates the record lifecycle and supports the next
experiment. It does not yet implement the candidate's verification-preservation
intervention or demonstrate its cross-task benefit. When that intervention is
built, review whether the small validation/held-out tasks actually exercise state
replacement before funding runs; otherwise build a more suitable cohort.
