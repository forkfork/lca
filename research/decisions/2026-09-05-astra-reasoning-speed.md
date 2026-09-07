# Astra reasoning-effort speed screen

User priority: time to a correct, verified solution. Compare explicit low, medium
and high reasoning with current prompt, tools, normal history and the same
clarified task contracts. High is the experimental control; interactive LCA's
unspecified effort is not assumed to mean high.

Preregistered theory: `evals/theories/astra_reasoning_speed_pilot.json`. Seed 911;
six independent smoke runs followed by 36 pilot runs (three coding tasks plus
arithmetic, three efforts, three repetitions). At most 42 launches, $10 estimated
cost threshold with one-run overshoot possible, 1800 active worker seconds.
This is independent of the prompt pilot; do not reuse its controls.

A candidate must retain per-task pass counts, reduce aggregate coding latency
by at least 20%, improve median latency on at least two of three coding tasks,
and increase aggregate cost by no more than 10%. Select the faster qualifying
candidate, breaking latency ties within 5% by cost. Exclude arithmetic/smoke from
the primary comparison, but account for their resources. Preserve failed runs.
A successful screen earns fresh held-out validation, not automatic adoption.

## Superseding registration before any model calls

The original screen never launched. New registration
`astra_reasoning_speed_pilot_v2` uses the fixed tagged-edit serialization and the
repaired compound-command grader in every arm. Add repeated_text_edit as a fourth
coding task; use two repetitions per cell for a bounded screening pass. Seed 912,
six smoke plus thirty pilot runs, at most 36 launches, $8 estimated threshold,
1800 active seconds. Require median latency improvement on three of four coding
tasks, alongside the unchanged aggregate latency/cost and per-task correctness
gates. Fewer repeats mean this can only select a validation candidate.

## Prospective held-out validation

Before seeing the completed screen, reserve existing_codebase_edit,
environment_recovery, context_boundary_edit and stable_verification_regression
as the next reasoning-validation cohort. These tasks are held out from the
low/medium/high screen, though some appeared in the earlier prompt experiment.
If an effort qualifies, compare it against explicit high with three repetitions
per task, retaining the same repaired scope contracts, current prompt and fixed
tools. Include arithmetic and an independent coding smoke. Continue to a
conditional recommendation only with no per-task correctness loss, at least
20% aggregate coding latency reduction, improvements on three of four task
medians, and no more than 10% aggregate cost increase. Preregister an executable
theory and bounded budget before launch. This is still not long-task validation
or evidence about LCA's unspecified endpoint-default reasoning effort.

## Completed screen results

Campaign `evals/results/20260905-astra-reasoning-speed-v2/` completed all 36 runs,
all passing, at $5.812976 standard-equivalent estimated cost and 1165.00 active
worker seconds. Every request audit passed; the source fingerprint was checked
before subsequent grader work. No campaign retry or protocol failure occurred.

Primary coding population: eight runs per effort (four tasks, two repetitions),
excluding smoke and arithmetic. All efforts passed 8/8.

| Task | High median | Medium median | Low median |
| --- | ---: | ---: | ---: |
| Ambiguous investigation | 44.6 s | 40.2 s | 41.5 s |
| Injected failure recovery | 40.6 s | 35.2 s | 41.8 s |
| Layered cancellation | 63.4 s | 51.0 s | 48.7 s |
| Pipeline edit | 42.4 s | 22.8 s | 20.6 s |

| Effort | Aggregate coding time | Coding cost | Model calls | Tools |
| --- | ---: | ---: | ---: | ---: |
| high | 382.066 s | $1.693380 | 45 | 79 |
| medium | 298.423 s | $1.565154 | 44 | 79 |
| low | 305.309 s | $1.491610 | 46 | 78 |

Medium reduced aggregate coding latency by 21.89% and cost by 7.57%, with lower
medians on all four tasks. Low reduced latency by 20.09% and cost by 11.92%, with
lower medians on three tasks. Both meet the screening gate. Their aggregate
times differ by less than the registered 5% tie band, so the lower-cost tie-break
selects **low for validation**, not because it was literally fastest. Low was
slightly slower on injected failure recovery. Small samples and a near-threshold
aggregate effect make independent validation essential.

All six post-fix pipeline artifacts match the intended replacement byte-for-byte.
The two high runs took 46.365 and 38.534 seconds, medium 25.670 and 19.848, low
21.641 and 19.631. This is regression evidence for the newline fix; comparison
with historical pre-fix runs is not a randomized estimate of its speed benefit.

## Validation launch contract

Theory `astra_low_speed_validation`, seed 913: four separate smoke cases followed
by thirty pilot cases, high versus low, three repetitions on the four prospectively
reserved coding tasks plus arithmetic. Maximum 34 launches, $7 estimated-cost
threshold, 1800 active worker seconds. No production reasoning default changes.

Before launch, held-out graders now require a completed, nonzero unittest summary
after recognized mutation events; a command start or plain `OK` does not suffice.
The checker distinguishes an unrelated trailing Git failure from a failed Python
probe, and uses the final test summary. Positive frozen artifacts still pass;
removing their verification events fails. Raw historical grades remain preserved
and affected current-session cells receive separate symmetric review files.

## Completed held-out validation: speed claim rejected

Campaign `evals/results/20260905-astra-low-speed-validation/` completed all 34
runs, all passing. Total estimated standard-equivalent cost was $4.680834;
active worker time was 818.708 seconds. Final source and manifest hashes matched,
and every cell passed request/configuration/usage audits. No retries or protocol
failures occurred. All 24 primary coding trajectories contain completed tests
after their native edits; their tool sequences contain no shell-edit workaround.

Primary population is twelve coding runs per arm, excluding independent smoke
and arithmetic. Each task passed 3/3 in both arms.

| Task | High median | Low median |
| --- | ---: | ---: |
| Corrected conversation context | 19.588 s | 19.741 s |
| Environment recovery | 39.191 s | 37.188 s |
| Existing multi-file codebase | 31.888 s | 38.071 s |
| Reproducible regression | 23.824 s | 30.307 s |

| Effort | Aggregate coding time | Coding cost | Model calls | Tools |
| --- | ---: | ---: | ---: | ---: |
| high | 348.854 s | $2.118848 | 57 | 84 |
| low | 375.431 s | $1.929494 | 57 | 84 |

Low was **7.62% slower**, although **8.94% cheaper**. It improved only one of four
task medians, failing both preregistered latency gates. Correctness and cost
gates passed. The initial screen's speed improvement did not replicate: **do not
recommend or adopt low as the speed setting from this experiment**. Keep the
production effort default unchanged. Medium remains an unvalidated screening
candidate, not a fallback winner that can bypass fresh validation.

Equal model/tool counts in this cohort give no evidence that lower reasoning
reduced interaction count. These small tasks cannot establish long-task
equivalence or a universal ranking of effort levels; endpoint latency and small
samples remain limitations. Reject the proposed promotion, not the possibility
that low can help some other workload. The independently reproduced tagged-edit
newline correctness fix is retained regardless of this negative result.

Full local installation and test gate before this campaign passed the Lua suite
and 93 Python tests. No runtime, fixture or grader source changed during collection.
The two completed reasoning campaigns together cost $10.493810 estimated;
including the earlier invalid/partial prompt campaigns, this work has a known
lower bound of $15.954974 plus one unfinished request with unknown final usage.
These are standard-equivalent estimates, not exact service-tier billing.
