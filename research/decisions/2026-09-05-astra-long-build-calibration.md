# Current Astra long-build calibration

Before testing planner removal, calibrate the current baseline on a complete API
build. Theory `astra_long_build_calibration`, seed 916: two independent smoke
runs, then four pilot runs, single current/Astra/high/all-tools arm. Maximum six
launches, $8 between-run estimated-cost threshold, 1500 active worker seconds.
No causal performance claim or default change is possible from this baseline.

The new `auth_api_strict` scenario preserves the historical API grader and wraps
its behavioral probes with hard gates for every tested requirement, final
completed unittest evidence, README preservation and no unrelated infrastructure.
It does not claim exhaustive security assurance: untested requirements, such as
all possible throttling-recovery behaviors, remain coverage gaps. The explicit
scenario contract standardizes final unittest verification and documentation scope.

Offline evidence: preserved build `20260824T050608Z-auth_api-lca_sol-1` passes all
old behavioral checks. A copy with `_token_hash` changed to return plaintext token
bytes still passes the old grader with score 95, despite `no_plaintext_token`
being false. The strict conversion makes this a mandatory failure, not a soft
score penalty. Original artifacts/grades remain untouched. Isolated negative
replay is preserved under `/tmp/lca-auth-negative-Oda6Xm`.

Record all three API builds, including separate smoke, without selecting only
slow runs. A long-workload label needs at least two builds with 20+ actual tools,
multiple code files and genuine verification failure/revision or changed
investigation assumptions. Count current planner calls and standalone planner
turns. Old repeated-plan trajectories are not evidence about today's once-only
planner. A single task family is not the requested diverse 20–50-task cohort.

## Deferred before model calls

The user raised concern about experimentation latency while the preceding
Git-facts campaign ran. A durable stop request was placed on this queued
calibration before it launched. State records zero completed cells, zero model
spend and an operator stop; no API build was sampled. Do not report a calibration
result or resume this frozen plan after source changes. Use a fresh registration
if longer-task calibration becomes the highest-value next experiment.

The strict grader's isolated end-to-end replays passed: the preserved good
implementation passed, while its plaintext-token mutation failed precisely the
`no_plaintext_token` gate (the legacy grader still passed that mutation). The
README was replaced with the new explicit task contract only in temporary replay
copies, leaving original artifacts untouched.
