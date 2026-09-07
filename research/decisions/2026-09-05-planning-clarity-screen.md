# Planning clarification: positive small screen

The clarification passed the registered screen: all six runs passed, one
standalone planning round disappeared, aggregate coding latency fell 10.7%,
and output tokens fell 16.3%. This justifies a fresh replication, not a production
prompt change. Estimated coding cost rose 1.7% because cache usage differed.

## Intervention and registration

Theory: `evals/theories/astra_planning_clarity_screen.json`.
Eval-only profile: `planning-clarity`, specified in
`evals/planning_clarification.json`. It adds exactly:

> For small, fully specified builds, proceed directly from inspection to implementation and verification, even when several files are involved. When a plan is useful and the first edits are already determined, issue the plan and edits in the same response.

The control retains the current prompt. Both arms include the recently added
realistic-test guidance, unchanged planning/tool schemas, Astra/high, normal
history, and the same task-specific file restrictions. Existing fixtures and
historical theories were not rewritten. Tool scope is all in both arms; tasks
explicitly prohibit browsing/network services.

Seed 920. Six serial runs: simple control first, with coding-task and adjacent
arm order randomized. Result order: simple current/clarification, checkout
clarification/current, cancellation current/clarification. Budget: six launches,
$2.50 between-run standard-equivalent cost threshold and 600 active seconds.
Stop on any task or protocol failure; no retries or discarded attempts.

## Results

| Task | Arm | Pass | Seconds | Model rounds | Standalone plan rounds | Output tokens | Estimated cost |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Simple | Current | Yes | 3.520 | 1 | 0 | 5 | $0.039272 |
| Simple | Clarification | Yes | 2.267 | 1 | 0 | 5 | $0.039732 |
| Checkout discount | Current | Yes | 31.023 | 4 | 0 | 977 | $0.163194 |
| Checkout discount | Clarification | Yes | 33.602 | 4 | 0 | 981 | $0.221872 |
| Order cancellation | Current | Yes | 64.570 | 5 | 1 | 2644 | $0.300568 |
| Order cancellation | Clarification | Yes | 51.726 | 4 | 0 | 2050 | $0.249670 |

Coding aggregates:

- Elapsed: 95.593 to 85.328 seconds, 10.7% lower.
- Output tokens: 3621 to 3031, 16.3% lower.
- Prompt tokens: 96124 to 83724, 12.9% lower.
- Cached prompt tokens (included above): 75392 to 57472.
- Estimated token cost: $0.463762 to $0.471542, 1.7% higher.
- Model rounds: 9 to 8; standalone plan rounds: 1 to 0.

All-attempt cost including controls: $1.014308 standard-API-equivalent estimate,
not actual subscription billing. Active worker time including grading: 187.521
seconds. No failed-run usage was excluded.

## What actually changed

Checkout used the same sequence in both arms: six reads together, three edits
together, one verification command, and final response. Both already skipped a
formal plan. The clarification was 8.3% slower on that task; there is no planning
mechanism benefit to attribute there.

Cancellation current: seven reads, standalone update_plan, three edits,
verification, final response. The plan response took 13.632 provider seconds,
including model generation, and supplied no new external evidence for the edits.

Cancellation clarification: seven reads, four edits, verification, final response.
It skipped the plan, retaining the same required architectural inspection. Both
changed only models.py, service.py, and api.py and passed public tests, hidden
idempotency/API/compatibility checks, scope checks, and post-edit verification.
Its task latency fell 19.9% and output tokens fell 22.5%.

The observed mechanism is skipping a formal plan, not batching a plan with edits.
The batching branch of the added instruction remains untested. The extra edit
in the clarified run also shows why raw tool counts are a poor round-trip metric:
both cancellation runs had 12 tool calls, but their model-round counts differed.

## Validation and preserved evidence

Narrow prompt-profile tests passed, including Lua/Python agreement on a real
prompt, preservation of project context and realistic-test guidance, and rejection
of altered outgoing prompts. Existing grader checks were exercised offline on
saved known-good workspaces, unimplemented fixtures, and deliberately broken
pricing/service files: positives passed and negatives failed.

`make check` passed, including the local LuaRocks install, Lua suite, and 107
Python eval tests. Campaign preflight also passed. Every live run passed the
campaign's model/reasoning, prompt-profile, usage, and tool-scope audits. The
post-run analyzer additionally compared every actual serialized provider
request's instructions to its frozen effective prompt; all matched.

Evidence directory:
`evals/results/20260905-astra-planning-clarity-screen/`

It contains the immutable manifest/content fingerprint, source.tar including the
dirty checkout, Git revision, original requests/responses/observations, unchanged
grades, task workspaces, preflight logs, and analysis.json with per-response
batch membership. Artifacts and evidence are outside each agent task workspace.
Historical positive artifacts were used only to test graders, not as live controls.

## Decision

Advance to a fresh small replication if further evaluation is requested. Every
predeclared gate passed: all runs correct, one fewer standalone plan round,
aggregate latency improvement above 10%, neither coding task more than 10%
slower, and no output-token increase above 10%.

Do not promote yet. There is one observation per arm/task, the aggregate speed
result narrowly exceeds the threshold, the mechanism changed on only one task,
and cache differences reversed the token-count improvement in estimated cost.
Keep the profile available for experiments; production planning instructions
remain unchanged. No further live runs are included in this decision.

## Subsequent user-directed adoption

After reviewing the screen and cache investigation, the user explicitly requested
keeping this approach and cleaning up the codebase. The clarification was promoted
to `lua/agent/tool_registry.lua` beside the existing planning guidance. Normal
small specified builds can proceed without a formal plan; useful plans can share
a response with already-determined edits. Rules for genuinely dependent work and
Insanitywolf remain in place. The realistic-test guidance remains active too.

The temporary profile and transform support were archived and removed from the
active eval path. Its old switch now fails early; historical manifests and original
results were not changed. This adoption follows the user's judgment, overriding
the default recommendation to replicate before promotion. The screen's evidence
and limitations above still apply; it has not become broader validation evidence.
