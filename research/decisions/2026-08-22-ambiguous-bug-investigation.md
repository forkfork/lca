# Ambiguous existing-codebase investigation baseline

## Decision

Keep the new `ambiguous_bug_investigation` scenario as a trajectory regression test.
Do not add generic “investigate before editing” prompt text or production control flow
based on this result: current LCA already follows the desired path reliably on this
class of bug.

## What the eval tests

The reported symptom is that a VIP quote can inherit a regular customer's price for
the same cart. The report deliberately names four plausible ownership layers without
identifying the root cause. The fixture spreads those layers across customer models,
discount policy, quote service, and cache modules.

Passing requires more than ending with green public tests:

- reproduce the named failure before the first successful source mutation;
- preserve regular, VIP, quantity, and tier-change behavior;
- prevent cache contamination in both regular-to-VIP and VIP-to-regular order;
- retain cache sharing for different customers with equivalent pricing inputs;
- rerun verification successfully after editing; and
- modify only the relevant production cache/service files.

## Result

Five runs with seed 841 passed 5/5 at 100/100. Every run saw one failing reproduction
before editing and a later green test suite. Every run read at least the four relevant
production modules (mean 4.2 relevant source reads) and made the same coherent two-file
fix: compute discount policy before cache lookup and include the resulting pricing
dimension in the key. Provider calls were five to six (mean 5.2), with elapsed time
from 23.3 to 29.2 seconds (mean 26.0 seconds).

The apparent tool-count outlier of eight was four plan-state updates around the same
read/reproduce/edit/verify path, not redundant code exploration. The only extra
verification in the sample was a compile check after the full suite had passed.

## Limits

The failing test is deterministic and the causal chain is small. This does not yet
cover misleading stack traces, flaky tests, environment failures, log-only incidents,
large call graphs, or competing fixes whose tradeoffs require architectural judgment.
Those should be separate scenarios so a failure says which investigation skill is
missing.
