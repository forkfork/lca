# Workflow prompt take/drop decision

## Registration

Seed 924. Six launches: current and workflow-lite at Astra/high on simple control then two randomized adjacent coding pairs. Maximum $1.75 between-run standard-equivalent estimated cost (one-run overshoot possible), 360 active seconds. No retries; stop for correctness, protocol or activation failure. Drop the implementation if any run fails or the completed screen misses any gate: at least 10% lower aggregate coding latency, neither task more than 10% slower, coding cost at most 10% higher. A positive screen does not promote: proceed to fresh broader repeated validation, preregistered before collection. Final adoption requires all repeated runs correct, at least 10% lower aggregate coding latency, no task median more than 10% slower, and cost at most 10% higher. Otherwise drop. Preserve raw evidence and archive/remove the workflow-lite implementation and switch after either final decision. No grader/source edits during collection.

Source: `085e3c89e42af31f96cefa0a22181835c461d062090b3e750f950dad4b661e74`. Exact source archive, runtime metadata and immutable manifest: `evals/results/20260906-astra-workflow-replication`.

## Decision: drop

All six runs passed artifact and actual-request activation checks. The source fingerprint remained unchanged throughout collection.

| Coding task | Current seconds | Slim seconds | Change |
|---|---:|---:|---:|

| ambiguous_bug_investigation | 34.531 | 40.641 | +17.69% |
| stable_verification_regression | 24.596 | 20.521 | -16.57% |

Aggregate coding time: 59.127 → 61.162 seconds (+3.44%). Coding cost: $0.390232 → $0.366292 (-6.13%). Model calls: 12 → 11. All-attempt standard-equivalent cost: $0.836448.

The earlier speed gain did not replicate. Aggregate time did not improve and investigation regressed more than the permitted 10%; no broader promotion campaign is justified by the registered rule. Keep the normal prompt and remove the exact nine-line deletion implementation and executable workflow-lite profile. This rejects this bundle for adoption on current evidence, not prompt simplification in general. A small screen is not a universal performance claim. Historical evidence is preserved unchanged.

## Trace review and cleanup

In the investigation pair both arms used six model calls. The slimmer arm split public and supplemental checks into separate tool calls and attempted Git diff in a non-Git fixture; the current arm combined the checks. In the regression pair the slimmer arm omitted a planner call and extra inspection/checks, using five model calls versus six. These are observed paths, not causal explanations established by one pair. All independent artifact, scope and verification gates passed.

Archived the exact transform/spec and original harness audit before deletion, with hash verification. Removed the Lua transform and JSON deletion spec, removed workflow-lite execution, and renamed the remaining generic prompt auditor to prompt_profiles.py. Old workflow-lite requests fail before workspace creation/model calls; historical registrations and results remain intact. No feature flag can enable the dropped prompt. Production prompt files are unchanged.

Validation: 25 focused harness/retirement tests passed, followed by make check (local LuaRocks install, full Lua suite, 108 Python tests). All production Lua files byte-match the frozen pre-experiment source. Post-removal test output is preserved with the campaign evidence.
