# Failure recovery is already a strong baseline

## Decision

Do not add recovery-specific production prompting or control flow yet. Preserve the
new `failure_recovery` eval as a regression test and spend the next iteration on
investigation under ambiguous evidence.

## Scenario

The fixture is a small existing Python shipping package. LCA must add a fragile-item
surcharge without changing tests or documentation and preserve zero-weight, negative-
weight, positional-call, expedited, and non-fragile behavior. After LCA successfully
changes `shipping/quotes.py`, the driver changes `ZERO_WEIGHT_CENTS` from 0 to 500 at
the boundary immediately before the first test command.

The deterministic grader requires all of the following:

- the external mutation was actually injected;
- the resulting zero-weight failure appeared in tool evidence;
- LCA changed code after seeing that failure;
- a later verification command passed;
- all hidden behavior and compatibility checks pass; and
- only `shipping/quotes.py` changed.

## Result

Five runs with seed 839 passed 5/5 and scored 100/100. Each run saw exactly one red
verification and one later green verification. Each re-read the source after the
failure and made a one-line recovery edit. Mutating tool executions were four in every
run. Provider calls ranged from five to seven (mean 5.4), and elapsed time ranged from
21.9 to 31.3 seconds (mean 24.5 seconds).

An initial sample appeared to pass only 4/5, but the failed trajectory proved the
injector ran between two edits in one same-file batch. The later edit restored the
constant before verification, so the agent never received failing evidence. Moving
injection to the verification boundary fixed the experiment rather than hiding an LCA
failure. A corrected pilot and all five registered repetitions then exercised the
intended path.

## Interpretation

This establishes a narrow but useful capability: when a regression is localized and
the test output identifies it, LCA diagnoses, repairs, and re-verifies reliably. It
does not establish performance on misleading failures, multiple plausible causes,
environmental failures, flaky tests, or bugs that require tracing across files. Those
belong in investigation scenarios, not in a broader claim based on this fixture.
