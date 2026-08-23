# Project-orientation reality contract

## Problem

In the initial LCA/Codex comparison, both agents passed project orientation, but
Codex gave a more useful mental model and more consistent starting points. The
repeated baseline was Codex 93.3 versus LCA 90.0 under the original grader.

## Iterations

All treatments used `gpt-5.6-sol`, native tools, high reasoning, the same fixture,
and five runs unless noted.

1. A broad answer contract improved coverage but added about 107 words and 59%
   latency. Rejected.
2. A 90-150 word contract improved score by six points over its randomized control,
   but did not reliably cover implementation reality. Rejected.
3. A dense contract improved architecture coverage but still inconsistently noticed
   documented components absent from the repository. Not adopted.
4. A reality-aware contract explicitly required checking documentation against the
   inspected tree and distinguishing intent, stubs, and missing components.

The iterations exposed deterministic-grader equivalence holes. Valid phrases such as
"currently skeletal", "planning is deliberately isolated from adapters", "separates
deterministic planning from credentialed execution", and "contains no adapters
directory" were undercounted. The matcher was generalized and regression tests were
added. Frozen LCA and Codex trajectories were then regraded; no agent output was
regenerated for that comparison.

## Regraded frozen comparison

| Variant | Runs | Passes | Mean score | Mean latency | Mean actions | Mean words |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Codex CLI Sol | 3 | 3 | 93.3 | 21.8s | 4.3 | 145.3 |
| LCA concise contract | 5 | 5 | 93.0 | 12.8s | 5.0 | 111.6 |
| LCA dense contract | 5 | 5 | 95.0 | 17.4s | 5.0 | 158.0 |
| LCA reality contract | 5 | 5 | 97.0 | 18.8s | 5.0 | 164.2 |

## Production confirmation

The reality-aware instructions were incorporated into the native system prompt and
the prompt version was bumped so saved sessions rebuild it. Three fresh runs through
the installed production prompt—not an eval-only append—scored 95, 100, and 95:

- pass rate: 3/3
- mean score: 96.7
- mean latency: 15.4s
- mean semantic actions: 5.0
- mean final length: 154 words
- unsafe execution or mutations: zero

Against the frozen Codex baseline, production LCA is +3.4 mean score and 6.4 seconds
faster on this scenario. Codex still uses 0.7 fewer semantic actions on average.

## Decision

Adopt the reality-aware orientation contract for native-tool agents. This is a real
user-facing improvement rather than phrase-specific eval optimization: it is
model-agnostic, names no fixture facts, and asks for evidence users need when entering
an unfamiliar repository—purpose, workflow, architecture, implementation reality,
and concrete entry points.

This establishes a win on project orientation only. It is not evidence that LCA
generally beats Codex on editing, diagnosis, authentication, or long-horizon tasks.
