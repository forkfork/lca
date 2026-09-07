# Faster exploration, separate from promotion

User feedback: the experiment loop itself is becoming too slow. The last
local-tools campaign used 28 model runs and 1058.466 active worker seconds; the
Git-facts campaign used 20 runs and 703.336 seconds. Cheap Python preflight took
about five seconds. Repeated live matrices, not these checks, dominate latency.

New default: explicit `study_kind: screen`, two arms, one sample each on a small
control and one or two coding tasks (4–6 calls to the agent runner, not 4–6 total
LLM requests). Task order and adjacent-pair arm order are randomized; no duplicated
smoke/pilot collection. Stop after a failed task or protocol audit, retaining its
cost and evidence. The manifest marks the decision as screen-only.

Register a short advance/park rule and budget. A positive result earns a fresh
replication, never a default change or a long-task claim. Negative/mixed small
samples usually park a candidate, not prove a universal negative. Keep rigorous
offline correctness/activation checks and independent grading. Deterministic
tool bug fixes can use failing/passing regressions without model campaigns.

The first use is `astra_workflow_fast_screen`, seed 917: current versus the
already-implemented nine-line procedural prompt ablation on simple_prompt,
failure_recovery and multifile_order_cancellation. Six runs, $1.75 estimated-cost
threshold, 360 active seconds. Explicit Astra/high and all tools in both arms.
Advance only if every run passes, coding time improves at least 10%, and neither
coding task regresses more than 10%. No promotion from this screen. Earlier
incomplete prompt runs and unrelated experiments are not controls.
