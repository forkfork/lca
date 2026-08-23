# Decision: enforce the context reserve inside the agent loop

Date: 2026-08-22

Decision: accepted as the production default. Check context pressure before every
model call in a tool-using turn, compact completed history when the reserve is
crossed, and never split the active human/tool turn.

## Evidence behind the hypothesis

LCA's REPL previously called automatic compaction only after `core.run_session`
returned. One `run_session` can perform up to forty model/tool iterations, so a turn
could cross the provider limit before the REPL regained control. A recent Pi/HN field
report described the same turn-boundary failure shape. Pi's compaction implementation
also explicitly avoids cutting at unsafe tool boundaries.

Code inspection found a second local issue: after replacing transcript messages,
LCA retained `last_usage`, whose token count and message index described the old
prefix. Usage-aware estimates after compaction were therefore not grounded in the
new transcript.

## Controlled result

The `context_boundary_edit` scenario seeds a superseded requirement, a later
correction, and bulky irrelevant history. After the first real tool result, the eval
injects a deterministic near-limit usage watermark. The hidden grader requires the
corrected values, exact file scope, and a verification command.

| Cell | Result | Compactions | Hard-limit stops |
| --- | ---: | ---: | ---: |
| Boundary-only edit | 0/5 | 0/5 | 5/5 |
| Intra-turn reserve edit | 5/5 | 5/5 | 0/5 |
| Boundary-only simple prompt | 5/5 | 0/5 | 0/5 |
| Intra-turn reserve simple prompt | 5/5 | 0/5 | 0/5 |

Every treatment edit retained timeout 90/retries 4 rather than the superseded 75/3,
changed only `pipelines/rules.py`, and ran verification. Treatment used 2–3 executed
tools and exactly one compaction per run. Both simple variants remained one model
call with zero tools, demonstrating that the reserve check itself does not create an
agentic detour below the threshold.

## Production behavior

- The reserve is checked before every provider call, including the first call after a
  large new user message.
- Compaction retains the latest non-tool user message and every assistant/tool message
  after it as one intact active turn.
- Successful transcript replacement clears `last_usage`; historical usage remains in
  `usage_history` for diagnostics.
- If compaction cannot reduce input below the model window without splitting the
  active turn, LCA stops instead of sending a predictably invalid request.

## Limits of this result

The eval deliberately uses a small injected boundary so it is affordable and
repeatable. It validates control flow, latest-correction retention, active-turn
integrity, and the below-threshold negative control. It does not establish the cost
or fidelity of summarizing a genuine 180k-token transcript. Rolling compaction versus
a fresh goal/checkpoint rebase remains a separate experiment.
