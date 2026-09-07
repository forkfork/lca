# Medium reasoning: fresh screen

## Registration

Change only Astra effort from high to medium. Both arms use the current full prompt, full tools and normal history regardless of the preceding prompt result. Context-boundary and environmental-recovery tasks were excluded from the original medium screen.

Seed 922. Six screen-only launches, one per arm on simple_prompt and two coding tasks. Simple control first, coding order and adjacent arm order randomized. Maximum $1.75 between-run standard-equivalent cost threshold (one-run overshoot possible), 360 active worker seconds. No retries. Stop on correctness, protocol or activation failure; retain all resource accounting. Advance only if all six pass, aggregate coding latency is at least 10% lower, neither coding task is more than 10% slower, and aggregate coding cost rises no more than 10%. Otherwise park this implementation pending a materially new hypothesis. Simple runs are excluded from coding effects but included in spend. A positive screen justifies fresh replication only, never a default change. Preserve current source and fixtures, audit actual requests, run grader positive/negative preflight and verify activation before continuing.

Source fingerprint: `c0eca426b5db94d270e9bc2aacc197ae5eb7fb6647f349c6d3dee23cc97cc806`. The immutable manifest,
exact source archive and pinned Lua 5.5 runtime metadata are preserved in
`evals/results/20260905-astra-medium-fresh-screen`. Correct/broken grader checks and `make check` passed
before live collection. This is a new campaign with fresh controls, not a resume
or replacement of old cells. Original grades and all attempted costs are retained.

## Decision

Do not advance from this screen. All six task and request/protocol checks passed.

| Task | high seconds | medium seconds | Change |
|---|---:|---:|---:|
| simple_prompt | 3.130 | 2.825 | -9.74% |
| context_boundary_edit | 18.690 | 19.252 | +3.01% |
| environment_recovery | 35.921 | 35.780 | -0.39% |

Coding time: 54.611 → 55.032 seconds (+0.77%). Coding cost: $0.369766 → $0.331124 (-10.45%). Model calls: 10 → 10; tool calls: 12 → 12. All-attempt standard-equivalent spend including simple controls: $0.783284.

Gates: all_pass=True, aggregate_speed_at_least_10pct=False, no_task_over_10pct_slower=True, coding_cost_increase_at_most_10pct=True.

One paired observation per coding task cannot separate stable effects from latency, cache or sampling variation. The result does not change production defaults or establish long-task behavior. Original grades, raw requests/responses/observations, workspaces, source archive and detailed metrics remain in the campaign directory.

Trace review: environment recovery used six model calls and seven tools in both arms; both observed the documented unavailable Python version, used /usr/bin/python3, changed only ledger/summary.py, and completed passing public and supplemental checks. The correction fixture used four calls and five tools in both arms and changed only two lines. Both retained the latest correction. Crucially, neither correction run triggered intra-turn compaction (count zero), so these are correction-retention measurements, not evidence about an actual compaction boundary. This limits the scenario claim but does not change the medium-versus-high latency result on the executed task. No retries or extra paid cells were launched.
