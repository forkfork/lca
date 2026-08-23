# LCA vs Codex CLI with GPT-5.6 Sol

## Question

Can the local behavior evaluations compare LCA with Codex CLI fairly enough to
identify agent-loop improvements, rather than merely rewarding one tool protocol?

## Method

- Use `gpt-5.6-sol` at `high` reasoning for both agents.
- Grade the final workspace and answer with the same deterministic scenario grader.
- Normalize Codex `command_execution` and `file_change` events into the same
  completed semantic-action view used for LCA tools.
- Require grader-equivalence tests: equivalent LCA and Codex trajectories must get
  the same hard gates, verification credit, mutation credit, and score.
- Treat scenarios independently. Call something a quality gap only when Codex
  passes at least 2/3 runs and leads by a pass or ten mean score points.
- Do not compare raw `llm_calls`: Codex CLI exposes its whole invocation as one
  opaque call while LCA exposes every provider round. Absolute prompt-token cost is
  also harness-sensitive.

Theory: `evals/theories/agent_loop_sol_comparison.json`

## Results

The complete one-run smoke covered five paths and passed 10/10 cells.

| Scenario | Codex | LCA | Codex actions | LCA actions | Interpretation |
| --- | ---: | ---: | ---: | ---: | --- |
| Simple prompt | 100 | 100 | 0 | 0 | Equivalent; neither overthought. |
| Project orientation | 95 | 80 | 3 | 5 | Initial quality gap, so repeated below. |
| Existing-code edit | 100 | 100 | 7 | 9 | Same outcome; LCA used finer mutations. |
| Ambiguous bug | 100 | 100 | 6 | 13 | Same outcome; LCA gathered more evidence. |
| Authentication API | 94 | 90 | 9 | 23 | Same hard gates; LCA was less action-efficient. |

Three-run comparisons on the high-signal, cheaper scenarios:

| Scenario | Codex passes / mean score / actions | LCA passes / mean score / actions |
| --- | --- | --- |
| Project orientation | 3/3 / 93.3 / 4.3 | 3/3 / 90.0 / 5.0 |
| Existing-code edit | 3/3 / 100 / 6.3 | 3/3 / 100 / 9.3 |
| Ambiguous bug | 3/3 / 100 / 7.0 | 3/3 / 100 / 12.7 |

No repeated scenario met the predeclared quality-gap threshold. LCA was actually
about 11 seconds faster per project-orientation run, 13 seconds faster per edit run,
and 3 seconds faster per ambiguous-bug run in these samples. Action count therefore
must not be treated as a proxy for latency or quality.

The single authentication run is still useful trajectory evidence. Both agents met
every hard gate and the same security checks. LCA took 303.5 seconds versus Codex's
238.2 seconds, but its estimated API cost was lower (`$0.504` versus `$0.595`). LCA
ran five verification commands, including recovery from one malformed smoke-test
command; Codex ran six commands and had two errored actions. The four-point score
difference was entirely the grader's coarse action-efficiency band, not a functional
or security difference.

## Decision

Keep the cross-agent harness. It is now useful for outcome equivalence and broad
trajectory comparison, but it does **not** establish that Codex is generally better
on these paths. LCA/Sol currently matches Codex's deterministic task success in the
tested scenarios.

Do not add a hard early-stop rule based on the auth trace. Some apparently extra LCA
work found and repaired real issues, and action count alone was anticorrelated with
latency in the repeated scenarios.

The best next controlled experiments are:

1. A multi-hunk tagged-edit interface that preserves stale-read rejection while
   allowing several independent replacements in one mutation call. Measure outcome,
   failed mutations, changed-line scope, actions, and latency on existing-code edit,
   repeated-text edit, and stale-edit recovery.
2. A trajectory rubric that labels actions as necessary, useful defense-in-depth,
   redundant, or recovery. This is better than a raw tool-count penalty for complex
   tasks such as the auth API.
3. A compact project-orientation answer contract: identify purpose, differentiators,
   runtime flow, and 3-5 concrete starting files. Test it as a prompt treatment; do
   not special-case the user phrase in Lua.

Repeat the expensive authentication comparison only when testing a specific
treatment. A fresh baseline by itself costs several minutes per cell and adds little
to the current decision.

## Follow-up

The project-orientation gap was subsequently closed with a reality-aware synthesis
contract. Three fresh production-prompt runs averaged 96.7 points and 15.4 seconds,
versus the frozen Codex baseline of 93.3 points and 21.8 seconds. See
`research/decisions/2026-08-22-orientation-reality-contract.md` for the rejected
treatments, grader-equivalence repairs, and adoption evidence.
