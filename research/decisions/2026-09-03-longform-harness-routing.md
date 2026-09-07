# Long-form harness routing and promotion decisions

Date: 2026-09-03

## Decisions

- Reject web-only tool routing for general research. It preserved correctness but
  missed the 10% efficiency threshold and regressed median latency by 23.5%.
- Do not promote a global model/reasoning route yet. Corrected frozen-trajectory
  grading leaves Terra/high and Luna/high at 4/4, but only one run exists per cell.
- Reject the deterministic completion receipt. Regrading the frozen trajectories
  after fixing a phrase-equivalence bug made both treatment and control 5/5.
- Accept a deterministic adjacent-regression gate for self-research implementation:
  /implement is successful only after make check passes in the authoritative engine
  checkout.

## Evidence

The web-only experiment used five randomized runs per cell (20 total). Research
medians were:

| Arm | Pass | Hosted searches | Input cost | Latency |
| --- | ---: | ---: | ---: | ---: |
| all tools | 5/5 | 10 | $0.3427 | 82.4 s |
| web only | 5/5 | 10 | $0.3318 | 101.7 s |

All ten simple-prompt runs passed in one call without hosted search. Web-only reduced
the simple prompt by roughly 777 tokens, confirming that the requested tool surface
changed even though end-to-end research did not improve.

The model/reasoning screen preserved every failed trajectory. Across four cells:

| Route | Passed | Failed cell | Median cost | Median latency |
| --- | ---: | --- | ---: | ---: |
| Sol/high | 3/4 | external API example | $0.4328 | 92.9 s |
| Terra/high | 4/4 | — | $0.1161 | 38.7 s |
| Terra/medium | 3/4 | external API example | $0.0949 | 32.7 s |
| Luna/high | 4/4 | — | $0.0217 | 80.3 s |

The completion-receipt experiment ran five randomized pairs. The original result
was confounded by an evaluator that rejected semantically valid external-boundary
phrasing. The corrected grader, with a negative test against “fully deployed”
overclaims, passes all ten original trajectories without rerunning the models.

For promotion safety, tests/test_experiment.lua injects both outcomes at the new
validation boundary. The failure path cannot return a successful promotion status.
tests/test_tui.lua verifies the surrounding UI lifecycle.

## Scope

The model screen is activation evidence, not promotion evidence. Terra/high and
Luna/high require replicated hard-gated cells; Luna's 29-tool API-build path is an
explicit efficiency risk. Terra/medium is also worth a separately preregistered
prose-research replication. No model default or web-only production route changed
in this round.
