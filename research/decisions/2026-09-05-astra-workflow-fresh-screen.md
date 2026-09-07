# Slimmer workflow prompt: fresh screen

## Registration

Remove exactly nine procedural lines using the existing audited workflow-lite profile. Both arms use Astra/high, full tools and normal history. Current planning clarification and concrete batching guidance remain fixed.

Seed 921. Six screen-only launches, one per arm on simple_prompt and two coding tasks. Simple control first, coding order and adjacent arm order randomized. Maximum $1.75 between-run standard-equivalent cost threshold (one-run overshoot possible), 360 active worker seconds. No retries. Stop on correctness, protocol or activation failure; retain all resource accounting. Advance only if all six pass, aggregate coding latency is at least 10% lower, neither coding task is more than 10% slower, and aggregate coding cost rises no more than 10%. Otherwise park this implementation pending a materially new hypothesis. Simple runs are excluded from coding effects but included in spend. A positive screen justifies fresh replication only, never a default change. Preserve current source and fixtures, audit actual requests, run grader positive/negative preflight and verify activation before continuing.

Source fingerprint: `c0eca426b5db94d270e9bc2aacc197ae5eb7fb6647f349c6d3dee23cc97cc806`. The immutable manifest,
exact source archive and pinned Lua 5.5 runtime metadata are preserved in
`evals/results/20260905-astra-workflow-fresh-screen`. Correct/broken grader checks and `make check` passed
before live collection. This is a new campaign with fresh controls, not a resume
or replacement of old cells. Original grades and all attempted costs are retained.

## Decision

Advance to fresh replication only. All six task and request/protocol checks passed.

| Task | current seconds | workflow-lite seconds | Change |
|---|---:|---:|---:|
| simple_prompt | 3.224 | 2.950 | -8.50% |
| failure_recovery | 41.786 | 37.348 | -10.62% |
| multifile_order_cancellation | 65.169 | 54.415 | -16.50% |

Coding time: 106.955 → 91.763 seconds (-14.20%). Coding cost: $0.487080 → $0.467028 (-4.12%). Model calls: 12 → 12; tool calls: 21 → 21. All-attempt standard-equivalent spend including simple controls: $1.034042.

Gates: all_pass=True, aggregate_speed_at_least_10pct=True, no_task_over_10pct_slower=True, coding_cost_increase_at_most_10pct=True.

One paired observation per coding task cannot separate stable effects from latency, cache or sampling variation. The result does not change production defaults or establish long-task behavior. Original grades, raw requests/responses/observations, workspaces, source archive and detailed metrics remain in the campaign directory.

Trace review: both recovery arms used seven model calls and nine tools, including a failed public check followed by repair and passing verification. Both multifile arms used five model calls and twelve tools. Current used update_plan and combined public/extra checks into one run; workflow-lite omitted the planner call and split those checks into two runs. Both preserved scope and passed hidden tests. The effective prompt shrank by 1,311 characters in the simple control (10,999 → 9,688). This screen supports a conditional timing signal, not a reduction in round trips; different cache hits affect the measured cost.
