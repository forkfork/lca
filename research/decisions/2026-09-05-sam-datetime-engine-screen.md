# Codex and LCA: small SAM datetime API screen

Both engines passed the same independent API checks. Codex completed this one
build 9.3% faster; LCA's reported standard-equivalent token cost was 22.4% lower.
This is a successful screen, not a general engine ranking or a default change.

## Registration and controls

Theory: `evals/theories/sam_datetime_engine_screen.json`.
Scenario: `evals/scenarios/sam_datetime_api/`.

Four serial runs, seed 90517, one per engine on simple_prompt and one API build.
Both invocations pinned gpt-6-astra/high, identical task and fixture, fresh task
workspaces. Randomized adjacent pairs yielded LCA then Codex on both tasks.
Intervention: the complete engine bundle, including its own system prompt and
tools. This does not isolate a specific loop mechanism. No subagents were used.
The API contract was assumed to mean AWS SAM with Python; no cloud deployment.

The registered budget was four launches, $4 between-run estimated-cost threshold
(one-run overshoot possible), and 1080 active seconds. Stop rules covered task,
protocol, and unknown-usage failures. All four completed without those failures.
The existing cross-engine run_once adapter was used through a frozen external
serial controller because campaign.py currently admits only LCA interventions.
The controller, manifest, dirty-source archive/content hash, engine revision,
Codex CLI version/launcher hash, fixture/grader hashes, and original evidence
are retained outside the task workspaces at:

`/home/tim/.local/state/lca/experiments/sam-datetime-20260905/`

## Results

| Task | Engine | Artifact / verification | Agent elapsed | Tool events | Estimated token cost |
| --- | --- | --- | ---: | ---: | ---: |
| Simple control | LCA | Pass | 3.623 s | 0 | $0.038672 |
| Simple control | Codex | Pass | 4.755 s | 0 | $0.041032 |
| SAM datetime API | LCA | Pass / pass | 99.761 s | 7 | $0.382560 |
| SAM datetime API | Codex | Pass / pass | 90.452 s | 5 | $0.492870 |

Total estimated token cost including controls: $0.955134.
Controller active worker time including grading: 198.996 seconds.
No failed attempts were discarded. API grading: 20 artifact gates and one
verification gate, all passed for each engine. Checks cover template wiring,
UTC/current time, explicit offsets, Melbourne seasons, New York DST boundary,
invalid inputs, route/method errors, test files, and documentation.

| API usage | LCA | Codex |
| --- | ---: | ---: |
| Prompt tokens | 49,036 | 83,590 |
| Cached prompt tokens (included above) | 38,400 | 62,720 |
| Output tokens | 4,756 | 4,429 |

These are harness-reported usage counts, not equal-context measures. Costs use
the frozen local price table ($10/M input, $1/M cached, $50/M output), exclude
service-tier adjustments, and are not actual subscription billing. Tool events
also differ in granularity: Codex grouped its file changes into one event; LCA
used several writes. Raw llm_calls are not comparable across the adapters.

## Validation and evidence limits

Before live work, the grader accepted a known-good artifact and rejected wrong
epoch values, wrong timezone offsets, wrong error statuses, missing verification,
and a malformed template. Equivalent Codex/LCA command evidence received the
same grade. All 106 offline Python eval tests passed, and make local succeeded.
No shared engine code was changed for this screen.

After completion, independent reruns of the generated suites passed: LCA 18
unit tests, Codex 14. Those independent reruns used Python 3.14.4. The original
Codex run additionally discovered Python 3.12.3 and passed all 14 tests on that
target runtime. LCA ran only on 3.14.4 and checked 3.12 syntax. The earlier report
incorrectly called Python 3.12 unavailable; the successful command result proves
otherwise. This correction preserves the original report as report-original.md.
Template structure and handler behavior were checked locally; SAM CLI, Docker, deployed API Gateway routing, and AWS Lambda
runtime behavior were not exercised. Test counts are not a quality ranking.
Command review found no deployment, AWS, browsing, installation, or delegation.

LCA request/response/observation files support model/reasoning activation checks.
Codex CLI 0.153.4 supplies invocation settings, normalized events, raw JSONL,
final answer, and aggregate usage, but this adapter does not expose raw provider
requests or per-response usage. Thus the Codex invocation check passed while
wire-level activation remains unverified. The engine comparison is observational
at that boundary; it does not meet full wire-evidence parity. Do not interpret
missing Codex provider metrics as zero requests or zero errors.

Original grades and artifacts remain unchanged. Additional command audit and
independent-test-rerun records are stored alongside the original results.
LCA project: `cell-0003/workspace`; Codex project: `cell-0004/workspace`.

## Decision

The requested test run succeeded with equivalent measured correctness. Keep both
artifacts and the new reusable scenario. No implementation change or winner is
justified by one build each. A fresh paired task is the appropriate next step if
further comparison is wanted; a causal or promotion study first needs equivalent
Codex wire tracing and broader validation.


## Follow-up: what LCA can learn from Codex

The strongest observed improvement is target-runtime verification. Codex's
`trajectory.json`, completed command `item_7`, records Python 3.12.3 and 14
successful tests. LCA checked Python 3.12 grammar using ast.parse under 3.14,
which does not establish runtime/library compatibility. A useful candidate rule:
when the project declares a runtime version, probe that executable and prefer it
for the first verification command; explicitly report an unavailable fallback.
The original grader did not distinguish target-runtime evidence, so equal
scores hid this difference. Original grades remain unchanged.

LCA also spent a standalone provider round on update_plan: response-0002.json
reports 14.612 seconds and 414 output tokens. It then generated all four file
changes together in response-0003. Codex has no visible separate plan-tool step
and grouped six file changes into one patch event. The candidate improvement is
to skip a standalone plan round for bounded scaffold tasks, or issue a useful
plan alongside the already-known initial writes. The frozen LCA prompt already
says not to separate plan updates from edits just for narration. This observation
suggests activation or task-sizing work rather than piling on another generic
instruction. The 14.612 seconds includes model generation; it is not measured
update_plan tool latency and cannot be subtracted as guaranteed savings.

A multi-file patch is convenient, but this run does not establish a model-round
advantage over LCA's already-batched writes. Five versus seven tool events also
hides different mutation granularity. Codex used two discovery commands where
LCA read the named README directly; copying that reconnaissance would add work.

Codex supplied .gitignore entries for __pycache__, *.py[cod], and .aws-sam/, plus
tests/__init__.py. These are inexpensive scaffold hygiene. Its tests used a
normal `from src.app import lambda_handler` import from the documented project
root instead of inserting src into sys.path. That is a simpler option for this
layout, not a universal packaging prescription.

Codex's 123-line test file retained spring/fall DST, negative fractional epoch,
non-hour offsets, invalid inputs and overflow. LCA's 163-line file also covered
malformed query objects and extra routing/type invariants. Both used frozen
clocks and table-driven cases. Fewer tests or lines should not become a target;
there is no large test-design advantage to copy here.

The runtime implementations are substantially alike: standard-library datetime
and zoneinfo, one JSON response helper, offset-aware conversion, integer epoch
arithmetic, and input/routing errors. LCA adds defensive query-shape handling.
No new datetime algorithm or architecture from Codex is missing in LCA.

Prioritize a fresh, separately registered screen of exact-runtime selection or
avoiding isolated plan rounds, one factor at a time. No production prompt or
engine changes are made by this comparison, and no further live calls were run.
