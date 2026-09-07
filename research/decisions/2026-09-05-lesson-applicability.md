# Lesson applicability stress pilot

## Question and scope

Does a small, deterministic applicability check improve outcomes over letting
Astra evaluate a conditional lesson against current repository evidence?

This follows the research discussion about returning no lesson when none applies
and retiring lessons when assumptions change. It is a deliberately small,
authored stress probe, not evidence of cross-task learning or promoted knowledge.
No production default or global instruction is changed.

The seeded advice says a pure text-only parser can cache results by source text
across file paths. In `lesson_cache_valid`, that contract still holds. In
`lesson_cache_stale`, the parser now depends on both the full path and text.
Correct reuse requires a different cache key. Both scenarios require preserving
order, caching falsey values, handling changed text, and keeping caches local to
one analysis call. Arithmetic is the unrelated overhead control.

## Registered comparison

- **none:** no lesson in the model input.
- **advisory:** always supply the conditional lesson as fallible reference data.
- **checked:** supply exactly the same advice only when its component and parser
  contract match the fixture's explicit metadata; otherwise supply nothing.

Model/reasoning: Astra/high throughout. Normal accumulated history in every arm.
No transcript deletion, learned retrieval model, or full ledger supplied.
Checked/none inputs are equivalent on stale/unrelated tasks; any difference
between them is sampling variation, not a special model capability.

Theory: `evals/theories/lesson_applicability_pilot.json`. Campaign:
`evals/results/20260905-lesson-applicability/`. Seed 908; six independent smoke
cells followed by eighteen pilot cells (two repetitions per task/arm). Smoke
results are not substituted for pilot repetitions. Budget: 24 launches, $6
between-run standard-equivalent estimate threshold, 1800 active worker seconds.

Primary comparison: checked vs advisory on stale tasks. Continue only for
repeatable correctness failures avoided, or at least 20% lower stale-task total
cost with no correctness loss and no >10% relevant-task median latency regression.
Otherwise retain normal behavior and do not expand the gate from this evidence.
These tiny cases cannot establish long-task value or robust statistical effects.

## Preflight

Known-good and known-bad grader tests passed, including stale text-only caching,
protected-file scope, missing verification, iterator input and falsey results.
Injection audits tested all nine task/policy combinations. Local install, the
full Lua suite, and all 83 Python tests passed before live execution. Runtime
source and configuration are frozen by the campaign fingerprint.

## Results and decision

All 24 runs passed (six smoke, eighteen pilot); estimated total cost $1.930710,
active worker time 333.32 seconds. No retries or activation failures occurred.
Pilot stale-task results, two repetitions per arm:

| Arm | Passed | Total estimated cost | Median elapsed | Tools per run |
| --- | --- | --- | --- | --- |
| none | 2/2 | $0.191828 | 20.58 s | 6 |
| advisory | 2/2 | $0.191272 | 19.79 s | 6 |
| checked | 2/2 | $0.192038 | 21.86 s | 6 |

Checked cost was 0.4% higher than advisory, not the registered 20% reduction.
Both stale advisory runs implemented the correct path-and-text key despite
receiving the old conditional advice. Relevant-task checked median latency was
8.2% lower than advisory, but that secondary result does not satisfy the primary
decision rule. All coding runs used six tools regardless of arm.

Do not expand or enable the gate in production from this evidence. The gate
mechanically withheld the intended advice but supplied no demonstrated benefit.
Keep normal no-experience behavior. The eval-only switch remains available for
harder future probes; the seeded lesson is not promoted. These two related small
fixtures have explicit contracts and ceiling-level correctness, so this result
does not reject applicability filtering on ambiguous or long tasks.
