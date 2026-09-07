# Explicit-state coding pilot

Date: 2026-09-05

## Decision

Reject this implementation of state-only context. Do not promote either state
variant or expand this version to the longer-task suite. Production remains normal
LCA. Retain the eval-only intervention and request auditor as experimental tools.

The pilot does **not** falsify every possible state-machine architecture, or establish
what happens on genuinely long coding tasks. It rejects the concrete combination of
prompt-requested state emission, model-rewritten summary fields, and replacement of
history after every tool batch. It failed the preregistered correctness gate and
showed substantial recovery overhead even when the resulting code was correct.

## Experiment

Six existing scenarios, three repetitions, three arms: 54 live runs, all using
GPT-5.6 Sol/high. Each scenario used seed 906 to randomize its nine runs; at most
three scenario runners were active concurrently. Four seed-905 smoke runs were
excluded from the reported sample. No inference intervention changed during the
54-run sample.

- A / normal: existing history, slimming, and compaction.
- B / state-only: original user instructions, current explicit state, and the
  latest tool batch. Previous assistant prose and encrypted reasoning are dropped.
- C / state plus history: the same state-output instruction as B, retaining normal
  history management.

Both treatments emit an `agent_state` JSON block alongside the next native action,
without a separate state-writing model call. The state has an 8,000-byte limit and
contains goal, beliefs, completed work, questions, next actions, constraints,
rejected hypotheses, and verification. Missing or malformed state fails the run
before that response's proposed tools execute; there is no silent fallback or
repair retry. The final answer also requires state.

Original user corrections are retained independently of model-written state. A
step is every completed tool batch, including a standalone plan update. Raw
observations remain retrievable outside the graded workspace. State-only made five
archive-read calls during the measured sample; retrieval was available in practice.

## Reviewed results

| Measure | Normal | State-only | State + history |
| --- | ---: | ---: | ---: |
| End-to-end passes | 18/18 | 9/18 | 16/18 |
| External artifact/trajectory grader passes | 18/18 | 12/18 | 16/18 |
| Missing-state failures | 0 | 9 | 2 |
| Total estimated API cost | $1.4291 | $2.2460 | $2.1736 |
| Median per-run elapsed time | 26.8 s | 45.7 s | 52.2 s |
| Sum of individual run elapsed times | 609.1 s | 1255.1 s | 930.6 s |
| Prompt tokens, including cached | 779,611 | 812,404 | 786,591 |
| Cached prompt tokens | 576,384 | 562,176 | 485,248 |
| Uncached prompt tokens | 203,227 | 250,228 | 301,343 |
| Output tokens | 19,282 | 51,011 | 38,704 |
| Model calls | 79 | 92 | 72 |
| Executed tool operations | 123 | 189 | 103 |
| Identical-content repeated reads | 0 | 65 | 0 |

Costs use the existing runner's estimates, including usage from rejected state
responses. Failed and early-aborted runs remain in every resource total. Their
shorter trajectories are not efficiency wins. Summed task times are not the elapsed
duration of the concurrent experiment. Repeated reads are exact path/content
matches, irrespective of requested line limit; these are review candidates, not
65 independently established semantic investigation failures.

State-only cost 57.2% more than normal despite aborting half its runs. State plus
history cost 52.1% more and did not improve correctness. Three state-only protocol
failures had already produced artifacts satisfying their external graders; their
code success does not repair their failed state protocol. All protocol-compliant
state-only runs passed their scenario graders, so this sample does not establish
an independent code-correctness penalty after protocol compliance is conditioned on.

| Scenario | Normal | State-only | State + history |
| --- | ---: | ---: | ---: |
| Ambiguous bug investigation | 3/3 | 1/3 | 2/3 |
| Multifile order cancellation | 3/3 | 1/3 | 2/3 |
| Stale edit recovery | 3/3 | 1/3 | 3/3 |
| Stable verification regression | 3/3 | 2/3 | 3/3 |
| Context-boundary correction | 3/3 | 1/3 | 3/3 |
| Simple prompt | 3/3 | 3/3 | 3/3 |

The correction fixture used its existing default limits, not a forced compaction
boundary. Its archived diagnostics are synthetic. These results are a short-task
pilot, not a long-context benchmark or a comparison against repeated real compaction.

## Failure mechanisms

**State emission is not a reliable prompt-only contract.** The model sometimes
returned valid native tool calls with no assistant text, omitting the required
state. This occurred in both treatments. All nine state-only end-to-end failures
were this protocol error, not JSON corruption or a size-limit rejection. Stronger
structured enforcement needs a new experiment, not reinterpretation of these
failures as successes.

**A plan acknowledgement evicted useful source.** In the successful
[multifile state-only run 1](../../evals/results/20260905T043642Z-multifile_order_cancellation-state_only-1/trajectory.json),
the model read seven files, issued a standalone plan update, and then reread all
seven files. The same run later retained "run the documented tests" while losing
the actual command. It tried `/usr/bin/pytest -q`, failed collection with an import
error, and reread the README to recover the documented unittest command. It
eventually passed, but took 34 operations and $0.3557. Normal multifile runs took
12–13 operations, with a median cost of $0.1405. This treatment run contains 17
identical-content rereads across several recovery batches.

**Verified completion was forgotten.** In
[bug state-only run 2](../../evals/results/20260905T044052Z-ambiguous_bug_investigation-state_only-2/trajectory.json),
state 6 correctly records that the current fixed repository passed three tests.
State 7 retains that fact. State 8 downgrades it to an earlier pass that must be
rerun; state 9 removes verification altogether. Only reads occurred in between.
The agent repeatedly revisited the same source, hit the read-only loop guard,
attempted a Git diff in a fixture without Git metadata, and ultimately reached 41
executed operations before a missing-state failure. Its external grader passes
the saved artifact. This is a confirmed loss of a completed fact, with 19 exact
repeated reads, not evidence that the patch itself was wrong.

These case reviews were not blinded, and no calibrated aggregate stale-belief
failure count is claimed. The pilot establishes protocol failures, exact reread
counts, and the cited state-loss episode. A longer experiment would need a frozen
semantic labeling rubric and independent review.

## Grader corrections and audit

Two false negatives were reproduced with focused tests after model runs were
collected:

1. The correction grader excluded `__pycache__` from the workspace but included it
   in the fixture. Existing fixture bytecode therefore appeared as an unauthorized
   deletion. Both sides now exclude cache artifacts. A real extra source/workspace
   file still fails scope control.
2. The arithmetic grader rejected `17 × 23 = **391**.` solely because the result
   was bold. It now accepts bold correct numeric results; wrong and conflicting
   answers still fail, as do unnecessary tools and model calls.

All 54 frozen workspaces were regraded with those corrections. Original
`result.json`, `grade.json`, and run-config grader hashes were retained. Separate
`artifact-grade.json` and `result-reviewed.json` files record the review and new
grader hash. Protocol failures remain failures even when their artifacts pass.

The auditor checked all 92 state-only requests against the exact projection of
original instructions, previous emitted state, and latest archived batch. It found
zero projection, native-pairing, or provider-reasoning leakage failures. The other
arms retained their histories. All measured runs recorded the same intervention
hash and engine-tree hash:

```
intervention: 29a16038e5fd827832ff68d0c60c8e978e1cf3332c29fa7510a99bd79de04e1a
engine tree:  00fe63e264ef2ecf03bc3562960a620b6330eb1ec7d3f80946a8a32dc6c84594
```

`make local` and `make test` passed, including all Lua tests and 58 Python eval
tests. The new tests exercise actual core callback ordering, state rejection,
user-correction retention, native call/output pairing, failed-call accounting,
archive retention, deliberate request leaks, and both grader regressions.

## Artifacts and next boundary

- [Preregistered pilot](../../evals/theories/state_only_pilot.json)
- [Per-run metrics and request audits](../../evals/results/state-only-pilot-seed906-analysis.json)
- [Eval-only context intervention](../../evals/state_context.lua)
- [Analysis tool](../../evals/analyze_state_pilot.py)
- [Frozen-workspace regrader](../../evals/regrade_state_pilot.py)

Reproduce a full sample with `python3 evals/run.py --theory state_only_pilot --seed
NEW_SEED`. Analyze it with `python3 evals/analyze_state_pilot.py --seed NEW_SEED`.
The measured seed-906 cohort was run by scenario, with up to three concurrent
runners; a single invocation runs sequentially and does not reproduce its
concurrency conditions.

If the architecture is revisited, first test an enforced action-and-state schema,
machine-maintained verification facts, and a bounded working set containing exact
commands and source spans. Also distinguish meaningful repository observations
from plan acknowledgements. Those are substantive changes to this implementation;
they require a new preregistered pilot before paying for a larger task set.
