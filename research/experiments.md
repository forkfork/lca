# LCA experiment backlog

These are hypotheses, not implementation commitments. Each experiment should become
an end-to-end eval with pinned model/provider settings and at least five runs before a
harness change is accepted.

Every executable experiment gets a pre-registered manifest in `evals/theories/` with
source IDs, control and treatment, falsification condition, deterministic outcomes,
efficiency outcomes, minimum runs, and a decision rule. Until the runner can actually
apply the treatment and the grader can observe its predicted effect, the theory is
`not testable yet`, not merely "pending".

## E1: Hybrid edit tool

Compare LCA's tagged ranges against multi-edit exact replacement and provider-native
patch format.

- Corpus: small surgical change, repeated block ambiguity, CRLF file, large file,
  multi-location same-file refactor, deliberate stale read, and syntax-error repair.
- Hard metrics: task tests pass, correct files changed, unrelated lines untouched,
  format/application failures, retry success, and stale-edit detection.
- Efficiency metrics: model calls, edit calls, bytes emitted, wall time, and total
  tokens per successful task.
- Decision rule: choose defaults per model family; retain a fallback if it materially
  improves recovery.

Status: **tested; keep tagged ranges as the production default**. The harness can
select tagged ranges or legacy exact replacement and now covers an existing-package
feature, repeated-text ambiguity, and a deterministic concurrent mutation after the
first read. Hidden graders check behavior, backward compatibility, concurrent-change
preservation, protected files, diff size, mutation failures, and verification.

Exact replacement passed the initial existing-codebase comparison 5/5 while tagged
ranges passed 4/5, then 3/5 in a confirmation. Those tagged failures were semantic
omissions, not edit-application failures. In the mechanics-isolating comparison both
formats substantively passed 5/5 on repeated text and stale recovery. Tagged ranges
used fewer calls and substantially less time and response data on stale recovery, so
there is no evidence to replace the production interface. Keep exact replacement as
an experimental fallback and add CRLF, large-file, and multi-location cases before
claiming the interface question is settled generally. See
`decisions/2026-08-22-edit-interface.md`.

## E2: Fresh goal rebase versus rolling compaction

Run the same long task under four policies:

1. Recent-turn rolling compaction only.
2. Structured phase checkpoints plus recent verbatim turns.
3. Fresh context at phase boundaries from original goal + checkpoint + worktree diff.
4. Provider-native compaction where available.

Seed early constraints, later corrections, stale file contents, failed tests, and an
unrelated side investigation. Score final behavior, constraint retention, stale-fact
errors, redundant reads/actions, recovery after compaction, and tokens per completed
task. The evaluator must inspect the workspace and trajectory; asking the agent what
it remembers is insufficient.

Status: **not testable yet**. The driver needs multi-turn scenarios, forced semantic
phase boundaries, and selectable continuation/rebase policies.

## E3: Deterministic versus model-written checkpoint

Compare a pure LLM summary with a machine-derived state packet and a merge of both.
The machine packet should include original goal, current user corrections, plan state,
modified/read files, git diff summary, last failing verification, and last passing
verification. Measure hallucinated completion, omitted constraints, and unnecessary
rediscovery.

Status: **not testable yet**. Capture checkpoints at the same boundary under each
policy and resume an identical hidden second phase.

## E4: Isolated exploration

For a repository-investigation task, compare direct exploration with a fresh-context
research worker returning a bounded report. Include a simple task as a negative
control: delegation should lose on latency/cost there. Measure task success, parent
context growth, duplicated reads, report fidelity, latency, and total tokens.

Status: **not testable yet**. LCA needs an eval-selectable isolated-worker treatment
and separate parent/worker token accounting.

## E5: Context drift tripwires

Test whether LCA should force a rebase when it observes repeated exact reads, repeated
stale-tag failures, contradiction between plan and worktree, or a second/third
compaction. Score whether the tripwire improves completion without causing premature
context resets.

Status: **not testable yet**. Add deterministic injection for stale edits, repeated
reads, and compaction count, plus a control that records but does not act on signals.

## E6: System-prompt diet

Compare the current instruction-heavy prompt with a minimal invariant core and a
minimal core plus task-selected guidance. Include a trivial prompt as a negative
control and auth/greenfield work where behavioral defaults matter. Measure pass rate,
tool count, latency, output tokens, conflicting-instruction failures, and safety rules
that are already enforced mechanically.

Status: **runnable** as `evals/theories/system_prompt_diet.json`. The treatment
consolidates generic context/response guidance while retaining grounding, verification,
tool protocol, and project context. `simple_prompt` is the negative control and
`auth_api` is the positive task. A more aggressive minimal-profile pilot remains
available in the driver, but it is not the registered treatment. This first experiment
does not yet test reducing the tool catalog itself.

## E7: Deferred capability schemas

Create a fixture with a large irrelevant MCP/tool catalog and one required hidden
capability. Compare all schemas upfront, compact discovery metadata with explicit
promotion, and a task-routed fixed subset. Measure task success, selection failures,
prompt-cache reads, latency, and total tokens per task.

Status: **not testable yet**. The fixture needs a synthetic large tool catalog and the
driver needs eager, discovery/promotion, and routed-subset variants.

## E8: Near-limit multi-tool turn

A recent Pi field report claims compaction checked only at turn boundaries can miss a
multi-tool turn that crosses the hard context limit. Seed the same session immediately
below the threshold, then require a chained read/edit/test/recovery sequence. Compare:

1. Turn-boundary compaction only.
2. A reserved per-turn token budget that prevents starting unsafe work.
3. A resumable mid-loop compaction checkpoint.

Hard metrics: completion, preservation of the latest user correction, no context-limit
error, correct workspace, and no duplicated mutation. Efficiency metrics: extra model
calls, discarded work, tokens, and latency. Include the same task far below the limit
as a negative control so defensive machinery does not tax normal turns.

Status: **accepted**. The driver now seeds prior conversation state and injects a
near-limit usage watermark after the first real tool result. Five turn-boundary-only
runs all stopped at the injected hard limit without completing the edit. Five
intra-turn-reserve runs all compacted exactly once, retained the latest corrected
values, preserved scope, and verified successfully. Both variants of the simple
negative control passed 5/5 with one model call, zero tools, and zero compactions.

Production now checks the reserve before every model call, compacts only history
before the active human turn, invalidates usage metadata tied to replaced message
indices, and refuses a call beyond the model window if the active turn cannot be
reduced safely. The small injected limit validates boundary behavior, not latency or
summary fidelity at a real 200k-token scale. See
`decisions/2026-08-22-intra-turn-context-reserve.md`.

## E9: Program orchestrator versus persistent agent orchestrator

Recent practitioners report that a long-lived agent should not perform orchestration
and implementation in the same growing context. Compare a persistent agent planner,
a deterministic program launching fresh issue-scoped sessions, and a hybrid that
periodically launches a fresh planner from verified repository state.

Score completed milestones, dependency/order violations, stale-state decisions,
coordinator context growth, worker duplication, total tokens, and wall time. Seed one
misleading worker summary; Git state and tests must outrank that summary.

Status: **not testable yet**. This requires a multi-session runner and deterministic
milestone queue. Source hypothesis: `reddit-long-running-agents-2026-08`.

## E10: Provider stream cap at the executable batch boundary

LCA's core executes at most ten tool calls from one model turn. Compare normal Codex
streaming with terminating the stream after ten unique, complete, valid tool calls,
then explicitly ask the model to continue after those results if work remains.

Hard metrics: exact workspace result and scenario gates. Efficiency metrics: elapsed
time, model/tool calls, provider response characters and transport bytes. Provider
token totals are diagnostic only because terminating a stream can suppress its final
usage event.

Status: **accepted**. Five uncapped and five capped `batch_many_files` runs all passed.
The cap reduced mean elapsed time by 28.4%, visible response characters by 27.4%, and
transport bytes by 23.9%, with no meaningful increase in model or executed tool calls.
The strengthened auth scenario and simple negative control also passed. See
`decisions/2026-08-22-stream-tool-call-cap.md`.

## E11: Provider cutoff for duplicate tool-call floods

Raw trajectories sometimes contained dozens of identical complete tool calls in one
Codex stream. The core discarded duplicates after generation, so compare uncapped
streaming with stopping after the third duplicate and resuming from accepted results.

Status: **accepted**. Across repeated-text and forced stale-edit recovery, all twenty
registered runs passed. The repeated-text negative control was effectively flat. On
stale recovery the cap reduced mean elapsed time by 39.8%, transport bytes by 22.5%,
and the observed maximum elapsed time from 49.1 seconds to 24.8 seconds, without more
model or tool calls. Five of ten capped runs actually triggered the cutoff. The
explicit value zero remains the uncapped control and rollback. See
`decisions/2026-08-22-duplicate-stream-cap.md`.

## E12: Evidence-driven recovery from a failing verification

Inject a deterministic regression after LCA completes its intended code edit but
immediately before its first verification command. Require the agent to observe the
specific failing test, mutate code after that evidence, rerun verification to green,
preserve the requested behavior and compatibility constraints, and touch only the
allowed production file.

Status: **baseline accepted; no production change justified**. In five corrected
runs, all five observed exactly one injected failing verification, re-read the changed
source, made one targeted corrective edit, and then passed the complete suite. Every
run scored 100 with the same four mutating tool executions; provider calls ranged
from five to seven. An earlier apparent 4/5 result exposed an eval flaw: injection
after the first edit in a same-file edit batch could be overwritten by a later edit.
The driver now injects at the next verification boundary after a successful target
mutation, making the causal sequence invariant to batch shape. See
`decisions/2026-08-22-failure-recovery-baseline.md`.

## E13: Existing-codebase investigation under ambiguous ownership

Give LCA a production symptom that could plausibly originate in customer state,
discount policy, quote calculation, or caching. Require a failing reproduction before
the first mutation, inspection of the relevant existing code path, a narrow fix, a
green verification afterward, and hidden behavior that rejects disabling caching or
keying it by irrelevant customer identity.

Status: **baseline accepted; no production change justified**. All five runs reproduced
the named failing test before editing, read at least four relevant production files,
fixed the pricing-sensitive cache key in `checkout/cache.py` and
`checkout/service.py`, passed the public and hidden behavior checks, preserved
equivalent-input cache reuse, and stayed within production scope. Provider calls
ranged from five to six. One run used four plan updates and another added a compile
check after the green suite; neither represented investigation churn or weakened the
result. See `decisions/2026-08-22-ambiguous-bug-investigation.md`.

## E14: Project orientation and stale resumed context

Turn the common “what is this project?” request into a trajectory-aware eval. Require
authoritative README and architecture reads, correct identity and operating model,
no mutation or command execution, no unsupported verification claim, at most five
lookups, and a bounded answer. Score distinctive details and useful starting points
without making prose style the sole pass criterion.

Status: **quality result quarantined after grader audit; token result retained**. GPT-5.5 passed the
fresh and seeded-auto-resume variants 5/5. Fresh context reduced mean prompt tokens
from 15,065 to 5,861 (61.1%) and output tokens from 444 to 319, but was 1.6 seconds
slower on average and the seeded runs did not reproduce stale-test leakage. The real
LCA trace remains valid evidence that auto-resume can surface an old `make test`
result, but this controlled sample establishes cost/context pressure rather than a
quality regression. Keep explicit fresh-versus-resume testing and do not silently
change persistence semantics from this single scenario. See
`decisions/2026-08-22-project-orientation-and-gpt-5-6.md`.

## E15: GPT-5.6 Sol orientation and grounding compatibility

Compare GPT-5.5 with GPT-5.6 Sol under the same LCA XML tool loop, then test a narrow
5.6-specific grounding rule. GPT-5.6 is interesting because official documentation
adds exact cache breakpoints, cache-write telemetry and pricing, a much larger context
window, and more concise default responses.

Status: **superseded as a model-quality comparison**. GPT-5.5 passed orientation 5/5 at 100.
Unmodified GPT-5.6 Sol passed only 1/5 (mean score 55): four runs answered directly
from shallow project-index metadata without reading authoritative files. A targeted
rule requiring immediate README/architecture read calls improved one registered
comparison from 1/5 to 5/5. A revised rule that also requested useful starting files
passed 4/5 at mean score 85; the remaining failure claimed inspection was unavailable
despite tools being available. The conditional rule had no effect on the simple
negative control: both variants passed 5/5 with one call and zero tools.

This is evidence of a model/protocol compatibility gap, not a reason to prompt-patch
indefinitely. Before a 5.6 default, test native Responses tool calling or a more robust
protocol bridge, correct 5.6 input/context limits, add explicit cache breakpoints only
after cache-write economics are observable, and rerun auth, edit, recovery, and
investigation suites. The ChatGPT-account endpoint accepted `gpt-5.6-sol` but rejected
the documented `gpt-5.6` alias. See
`decisions/2026-08-22-project-orientation-and-gpt-5-6.md`.

## E16: GPT-5.5 versus the GPT-5.6 Sol, Terra, and Luna tiers

Run the unchanged project-orientation agent path five times per tier. Compare hard
grounding and safety gates before latency, token counts, and estimated published API
cost. This tests model/protocol compatibility, not merely prose preference.

Status: **pass-rate ranking quarantined after grader audit; raw trajectories retained**.
The original result suggested keeping GPT-5.5 as the default, investigating Terra,
and repairing the 5.6 tool boundary. GPT-5.5 passed 5/5 at mean score 100. Terra was the closest 5.6 tier at
4/5, score 86, and 11.5 seconds versus 13.1 seconds for 5.5. Sol passed 2/5 at score
65; its successful runs were excellent and its 8.2-second mean partly reflects three
ungrounded shortcut answers. Luna passed 1/5 at score 68 and was slowest at 18.4
seconds despite its much lower published token price.

Approximate per-run API-equivalent costs from observed tokens were $0.0184 for 5.5,
$0.0128 for Sol, $0.0097 for Terra, and $0.0019 for Luna. These are comparison
estimates because the ChatGPT Codex endpoint may be subscription-metered. Cost does
not override failed trajectory gates. LCA's eval runner now reports this estimate for
known tiers, and its runtime now represents the documented 1.05M context window and
922k maximum input instead of prematurely compacting 5.5 at 184k and generic 5.x at
384k. The context-limit correction is independent of the quarantined quality score.
See `decisions/2026-08-22-project-orientation-and-gpt-5-6.md`.

## E17: Audited LCA versus Codex project-orientation baseline

Replace tool-prescriptive grading with separate outcome, evidence, safety, and
efficiency sections. Normalize LCA reads and Codex read-only shell discovery into the
same semantic evidence contract, retain every registered workspace, and record grader
and fixture hashes. Calibrate with adversarial examples before live runs.

Status: **baseline accepted; do not infer general agent superiority**. The grader has
five focused adversarial tests, all mutating graders reject a no-op in a suite-wide
smoke test, and theory manifests are schema/source validated. On five fresh identical
Rill runs, Codex CLI Sol passed 5/5 at mean 94, LCA GPT-5.5 passed 5/5 at mean 85,
and LCA Sol passed 2/5 at mean 52.8. Codex earned full evidence credit and more
consistently described the current skeleton; LCA 5.5 was reliable and faster; three
LCA Sol runs skipped inspection. See
`decisions/2026-08-22-project-orientation-and-gpt-5-6.md` and
`eval-audit-2026-08-22.md`.

## E18: Recovery from an unavailable pinned runtime

Give both LCA and Codex CLI the same dependency-free Python change in an environment
where the documented `python` command deterministically reports a missing pyenv
runtime while `python3` remains available. Require observation of the real failure,
a safe fallback, a production mutation after the failure, public and hidden behavior,
green relevant verification, and no changes to tests, documentation, or environment
configuration.

Status: **baseline accepted; no production change justified**. LCA Sol and Codex CLI
Sol both passed 5/5 on outcome, evidence, and safety. LCA averaged score 100, 28.0
seconds, and 3.4 command attempts; Codex averaged score 95, 35.9 seconds, and 6.0
command attempts. The score difference is only an optional efficiency diagnostic.
Codex commonly appended Git inspection in a workspace without `.git`, causing an
otherwise-green compound verification to return nonzero and require a clean rerun.
LCA's recovery was already reliable and more bounded on this case. The next scenario
should test a less explicit and more ambiguous environment/application boundary.
See `decisions/2026-08-22-environment-recovery-baseline.md`.

## E19: Credential blocker versus application loader bug

Present the same missing-payment-credential symptom in two evidence contexts. In one,
the documented environment variable is absent and the correct outcome is a precise
external blocker with no mutation. In the other, that variable is provisioned but
the application reads a misspelled name, so the correct outcome is a narrow loader
fix followed by green diagnostics and offline tests.

Status: **baseline accepted; no production change justified**. LCA Sol passed both
cells 5/5 with score 100. Codex CLI Sol also passed both cells 5/5 after saved
trajectories were graded by the corrected semantic command contract. LCA averaged
20.8 seconds on the blocker versus Codex's 30.1 seconds, and 23.9 seconds on the
loader bug versus Codex's 23.8 seconds. LCA never fabricated or persisted a secret,
never mutated the true-blocker workspace, and always limited the loader fix to
`payments/config.py`.

The smoke and one registered Codex run exposed a grader flaw: compound commands can
record a failing diagnostic and a passing test while returning the final subcommand's
status, or can record green diagnostic/test statuses before a trailing non-Git
inspection returns nonzero. The graders now recognize the actual subcommand evidence
from output and ordering rather than treating aggregate shell status as every
subcommand's status. Adversarial tests cover both shapes. See
`decisions/2026-08-22-credential-boundary-baseline.md`.

## E20: External port ownership versus application port-loader bug

Present the same address-in-use symptom across two ownership boundaries. The external
conflict requires observing the failure, preserving a scenario-owned unrelated
listener, leaving the workspace unchanged, and verifying with `APP_PORT=0`. The
application defect provisions `APP_PORT=0` but deliberately reads `OCCUPIED_PORT`, so
the correct response is a one-file loader fix followed by green checks. The runner
allocates a fresh loopback port, starts and observes the exact background process,
shares its environment with the agent and grader, and terminates only that process.

Status: **baseline accepted; no production change justified**. LCA Sol passed both
cells 5/5. Codex CLI Sol also passed both cells 5/5 after replaying one preserved
trajectory under the corrected reporting contract. LCA averaged 26.0 seconds and
42.5k prompt tokens on the external conflict versus Codex's 25.5 seconds and 90.0k;
on the loader bug LCA averaged 28.2 seconds and 63.5k prompt tokens versus Codex's
24.2 seconds and 92.1k. LCA's mean API-equivalent estimate was lower in both cells,
while Codex used materially fewer tool and model turns.

The live aggregate initially recorded 19/20 because the grader did not recognize the
clear phrase “the original process was not disturbed and still owns the port.” The
saved trajectory had observed the conflict, verified `APP_PORT=0`, preserved the
listener, and made no changes or kill attempts; replay with a fresh controlled owner
passed at score 90. A regression test now covers that exact paraphrase as well as
Codex's quoted shell wrapper. See
`decisions/2026-08-22-port-ownership-baseline.md`.

## E21: Transient verification failure versus stable code regression

Give both engines the same renewal-total report, README, command, tests, and public
failure text. In the transient cell, a per-run external state file makes the first
documented check fail once while the implementation is already correct. In the stable
cell, the implementation reproducibly ignores a credit. Require no mutation plus
accurate recovery evidence in the first case, and a one-file production repair plus
public and hidden green behavior in the second.

Status: **baseline accepted; no correctness change justified**. LCA Sol passed both
cells 5/5. Codex CLI Sol also passed both cells 5/5 after replaying one preserved
trajectory under the corrected reporting vocabulary. Every behavior observed the
initial failure, chose the correct opposite mutation policy, and reached green.
Observed final answers exposed several equivalent descriptions of transient behavior
that a literal phrase list initially missed; regression tests now cover “not a
reproducible defect,” “failure once,” and “one-time simulated failure.” See
`decisions/2026-08-22-verification-boundary-and-runtime-inventory.md`.

## E22: Startup runtime executable inventory

Resolve a deliberately small set of common executable aliases from `PATH` in-process
with `luv.fs_access`, without launching programs or querying versions, and expose the
stable result compactly in the frozen session prompt. The motivating defect was not
incorrect task behavior but repeated attempts to run unavailable `python` before
recovering to the available `python3`.

Status: **accepted**. All five pre-inventory transient runs invoked bare `python`; none
of five post-inventory runs did. Effective correctness remained 5/5 in both transient
and stable cells. On the transient cell, mean tools fell from 14.6 to 12.6,
verification commands from 7.0 to 6.0, and latency from 32.1 to 29.6 seconds. On the
stable cell, tools fell from 11.0 to 10.0, model calls from 8.2 to 7.4, and latency
from 26.4 to 24.5 seconds. The transient cost estimate was effectively flat/slightly
higher because output variation dominated the small input reduction. A simple-prompt
negative control still passed with one model call and zero tools.

The measured warm PATH scan for 19 names was about 0.1 ms locally. Versions remain
lazy: ecosystem wrappers such as `pytest --version`, `npm --version`, and
`luarocks --version` took tens of milliseconds each. The advertised list intentionally
excludes Ruby, JVM, Bun, Deno, Docker, and other speculative ecosystems. See
`decisions/2026-08-22-verification-boundary-and-runtime-inventory.md`.

## E23: Evidence sufficiency after failed verification

Add a compact stopping rule that distinguishes sufficient causal evidence from
duplicate confidence gathering. Test it against the paired transient/stable boundary
and an ordinary existing-codebase edit, five runs per variant and scenario. Require
no correctness or safety regression, at least 4/5 treatment passes in every cell, a
25% transient verification reduction, and preserved post-edit verification.

Status: **accepted and shipped**. Audited effective correctness was 30/30. One raw
control result was a grader false negative caused by an unrecognized but correct
final-answer paraphrase; the saved trajectory passes after the vocabulary correction,
which now has a regression test. Treatment runs themselves were 15/15.

On the transient cell, the treatment reduced mean tools from 13.0 to 7.0,
verification commands from 5.6 to 2.8, model calls from 8.2 to 4.6, latency from 30.8
to 15.9 seconds, and estimated API-equivalent cost from $0.0911 to $0.0543. On the
stable regression, tools fell from 10.8 to 8.0, verification from 2.8 to 2.0, model
calls from 8.2 to 6.2, and latency from 29.5 to 20.1 seconds. The ordinary edit
control remained 5/5 with exactly one verification command in both variants, though
the treatment had small run-to-run overhead: 26.6 versus 24.7 seconds.

Fresh checks using the installed production prompt passed all three scenarios. The
transient run used eight tools and four model calls, the stable repair used seven
tools and five model calls, and the simple-prompt negative control still used one
model call and zero tools. See
`decisions/2026-08-22-evidence-sufficiency.md`.

## E24: Layered multi-file order cancellation

Add a realistic dependency-free package with separate model, repository, service,
and JSON API layers. Ask the agent to implement validated, per-order idempotent
cancellation while preserving shipping, querying, imports, error shapes, and audit
behavior. Grade public and hidden behavior, production-only scope, inspection before
mutation, coherent layer ownership, and successful post-edit verification.

Status: **baseline accepted**. After grader calibration, LCA Sol and Codex CLI Sol
both passed 3/3 with score 100 on the identical clarified fixture. LCA averaged 14.0
tools, 8–11 model calls, 59.4 seconds, 90.2k prompt tokens, two verification runs,
and an estimated $0.1391 per run. Codex averaged 5.3 semantic tools, one long model
turn, 48.6 seconds, 106.6k prompt tokens, 4.3 command-based verification actions,
and an estimated $0.1487. Raw tool and model-call counts are not interface-equivalent,
but wall time, behavioral gates, and workspace results are useful comparisons.

The first Codex pilot exposed two eval defects rather than an agent-loop conclusion.
The phrase “non-empty after trimming” did not state unambiguously whether whitespace
was part of request identity, so the fixture now explicitly requires trimmed storage
and comparison. A correct Codex run also combined green tests with a trailing Git
inspection that failed only because the temporary workspace is not a Git repository;
the grader now preserves the successful test-subcommand evidence, with regression
tests. Fresh results after both corrections were 6/6.

Every fresh LCA run hit the core four-call batch cap once during architectural
discovery. This is a useful candidate for a controlled treatment, not evidence by
itself that the cap should increase globally. See
`decisions/2026-08-22-multifile-order-cancellation-baseline.md`.

## E25: Six-call read-only discovery allowance

Compare the existing five-call read-only batch cap with six calls while leaving the
general ten-call cap, mutation ordering, shell execution, read-byte budget, and
read-loop guard unchanged. Test the layered multi-file feature, the smaller existing
codebase edit, and a simple no-tool prompt.

Status: **accepted and shipped**. On the multi-file scenario, both variants passed
3/3 at score 100. Six reads reduced mean model calls from exactly 9 to exactly 7,
latency from 61.8 to 50.2 seconds, tools from 14.7 to 13.7, prompt tokens from 93.6k
to 70.9k, and estimated API-equivalent cost from $0.1501 to $0.1349. It admitted the
documented test file during initial discovery, allowing public and focused checks to
be combined after the edit; the seventh request for `orders/__init__.py` remained
deferred, so the guard still constrained inventory.

The smaller existing-codebase edit passed 3/3 in both cells with exactly four model
calls and one verification. Six allowed one additional read and averaged 27.8 versus
25.6 seconds, an 8.5% regression within the predeclared 10% tolerance. Both simple
prompt cells passed 3/3 with one model call and zero tools. The production default is
now six, with an internal override retained for experiments. A fresh installed-default
multi-file run passed at score 100 with seven model calls, six relevant source reads,
and one verification. See
`decisions/2026-08-22-read-only-discovery-cap.md`.

## Acceptance discipline

- Do not combine deterministic correctness and model-judge ratings into one number
  until judge scores have been calibrated against human labels.
- Report distributions and pass rates, not one cherry-picked trajectory.
- Preserve failed trajectories; they are more useful for harness work than averages.
- Change one harness variable at a time when attributing improvement.
- Do not call material useful merely because it sounds plausible. Record whether it
  generated a runnable theory, which outcome discriminates treatment from control,
  and the resulting effect across repeated runs.
