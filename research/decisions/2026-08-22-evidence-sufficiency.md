# Evidence sufficiency

Date: 2026-08-22

## Decision

Ship the tested evidence-sufficiency rule in LCA's system prompt. It tells the agent
to stop after distinct checks resolve the active uncertainty, while preserving a
clear escalation path when failures reproduce or source evidence conflicts.

The rule is intentionally behavioral rather than a runtime-enforced command budget.
Different changes need different evidence, and a hard cap would turn an efficiency
optimization into a correctness risk.

## Experiment

The registered theory compared the existing production prompt with the same prompt
plus the proposed rule over five runs in each of three scenarios:

- a one-time external verification failure where source is already correct;
- a reproducible application regression requiring a narrow production edit;
- an ordinary existing-codebase edit requiring compatibility verification.

The acceptance rule required at least 4/5 treatment passes in every cell, no loss in
outcome, evidence, or safety, at least a 25% reduction in transient verification, and
preserved verification after ordinary edits.

| Scenario | Variant | Effective passes | Mean tools | Mean model calls | Mean verification | Mean latency | Mean estimated cost |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Transient | Control | 5/5 | 13.0 | 8.2 | 5.6 | 30.8 s | $0.0911 |
| Transient | Treatment | 5/5 | 7.0 | 4.6 | 2.8 | 15.9 s | $0.0543 |
| Stable regression | Control | 5/5 | 10.8 | 8.2 | 2.8 | 29.5 s | $0.0951 |
| Stable regression | Treatment | 5/5 | 8.0 | 6.2 | 2.0 | 20.1 s | $0.0666 |
| Existing edit | Control | 5/5 | 9.4 | 4.4 | 1.0 | 24.7 s | $0.0670 |
| Existing edit | Treatment | 5/5 | 9.6 | 4.6 | 1.0 | 26.6 s | $0.0757 |

The registered aggregate was raw 29/30 because one correct control answer used a
previously unrecognized description of the transient condition. Audit of the saved
trajectory established that it observed the failure, made no mutation, obtained the
required independent green evidence, and reported the correct boundary. The grader
vocabulary and its regression tests now cover the observed wording. Treatment was
raw 15/15, so the adoption result does not depend on correcting a treatment failure.

## Shipped rule

The production prompt now says:

- gather enough evidence to resolve the active uncertainty, then stop duplicate
  confirmation;
- after a non-reproducing failure, one rerun plus one independent relevant green
  check is sufficient when source and tests agree and no evidence conflicts;
- after a reproducible failure or source contradiction, make the narrow fix and run
  relevant verification once, expanding only for a concrete risk or another failure;
- do not run Git status or diff solely to prove that no mutation occurred.

The session prompt version moved to 15 so saved sessions rebuild the frozen prompt
and receive the rule while retaining stable prompt-prefix caching afterward.

## Production validation

After `make check` passed, fresh installed-prompt runs produced:

- transient failure: score 100, eight tools, four model calls, four verification
  commands including the injected initial failure;
- stable regression: score 100, seven tools, five model calls, two verification
  commands;
- simple prompt: score 100, one model call, zero tools.

The existing-codebase cell shows the honest tradeoff: the treatment did not reduce
an already-minimal single verification and had small latency/token variance. Its
value is concentrated in ambiguous failure recovery, where it approximately halved
verification and latency without changing the mutation decision.
