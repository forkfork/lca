# Hosted search availability on offline coding

Hypothesis: removing unused hosted search reduces solution latency by lowering
tool-context or selection overhead. This is a hypothesis, not an API guarantee.
[Official configuration documentation](https://developers.openai.com/api/docs/guides/tools-web-search)
establishes that hosted search is enabled through the tools list; it does not
establish the marginal latency of an unused tool.

Preregistered executable theory: `astra_local_tools_speed`, seed 914. Four
independent smoke runs, then 24 randomized pilot runs (three coding tasks and
arithmetic, three repetitions, two arms). Explicit Astra/high and current prompt
in both arms. Budget: 28 launches, $7 between-run standard-equivalent cost
threshold, 1800 active worker seconds. Source and task contracts frozen before
launch. Both arms are explicitly instructed not to browse. This is not a network
sandbox and does not remove shell network capabilities.

Require unchanged per-task pass counts, at least 15% lower aggregate coding time,
lower medians on two of three coding tasks, and no more than 10% cost increase.
Arithmetic and smoke count toward spending but not the primary speed comparison.
A successful screen requires fresh held-out validation; no production default
change from a small pilot. The reserved validation tasks are existing_codebase_edit,
context_boundary_edit and stable_verification_regression.

Payload tests check that local-only removes exactly hosted search for both the
ordinary and optional delegation/DAG schemas. Native tools, prompts and tool
selection settings are preserved. A provider callback archives the actual
serialized request immediately before transport; per-request audits check the
activated tools, model, effort and prompt. Compare measured input attribution,
not just local JSON bytes, when deciding whether the mechanism actually shrinks
context. The earlier low-effort speed claim was rejected after held-out validation;
this new comparison holds effort fixed.

## Completed result: below speed-promotion threshold

All 28 runs passed. Campaign cost was $4.797506 standard-equivalent estimated;
active worker time was 1058.466 seconds. Source/manifest fingerprints matched
at completion. Every outgoing payload passed the native-schema and activation
audits, and coding trajectories contained completed verification after edits.

Primary coding population: nine runs per arm. Each task passed 3/3 in both arms.

| Task | All tools median | Local-only median |
| --- | ---: | ---: |
| Ambiguous investigation | 46.342 s | 43.561 s |
| Injected recovery | 50.075 s | 47.396 s |
| Multi-file cancellation | 66.699 s | 58.647 s |

| Scope | Coding time | Estimated coding cost | Model calls | Tools |
| --- | ---: | ---: | ---: | ---: |
| all | 496.130 s | $2.415482 | 58 | 103 |
| local_only | 437.052 s | $1.714340 | 55 | 103 |

Local-only reduced aggregate coding time **11.91%** and estimated cost **29.03%**.
All three task medians improved. Nevertheless, the preregistered 15% speed gate
failed: **do not promote this as the speed setting or launch the conditional
validation from this screen**. Retain the experimental option and evidence;
do not change normal browsing defaults. The cost signal is interesting but was
not the user-prioritized promotion criterion. A future cost-focused study would
need its own prospective decision rule, not a retroactive threshold change.

Actual provider usage attribution consistently reports 5,212–5,214 tool-input
tokens with hosted search available (68 responses), versus 776–778 without it
(65 responses), medians 5,213 and 777. Native serialized schemas are identical;
only hosted search differs. This establishes a substantial model-input reduction
in this endpoint/configuration, not a universal hosted-tool token price. Total
coding prompt tokens were 573,078 versus 291,001; cached tokens 454,272 versus
202,880; output tokens 15,463 versus 12,605. These totals include trajectory
differences and must not all be attributed directly to schema removal.

All-tools cell-0008 spent 92.050 seconds including a failed Git check that
prevented its chained tests from running. It remains in the primary population.
Git-related failed commands occurred in both arms; this separate environment
assumption is the next speed hypothesis. Local installation/full tests before
launch passed the Lua suite and 95 Python tests.
