# Astra workflow prompt ablation

## Registered question

Does deleting accumulated procedural guidance improve Astra coding efficiency
without sacrificing correctness? This is the first back-to-basics test; planner,
tool-interface and reasoning-budget changes remain separate experiments.

Official OpenAI guidance flags stronger instruction sensitivity in Astra:
https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices
That motivates this local hypothesis; it does not establish its outcome.

Treatment: `evals/prompt_ablation.json` deletes nine exact lines spanning both
`system_prompt.lua` and the registry's embedded strategy. It removes selected
discovery/rereading prescriptions, mandatory round-trip minimization, command
bundling and the long-task early-summary suggestion. It is not a bare prompt,
nor a pure token-length test. Tool schemas, tagged-edit requirements, concurrent
mutation safeguards, planner policy, verification sufficiency, project context
and scope protections remain unchanged. Project instructions are never edited.
Production sessions never install this intervention.

Theory: `evals/theories/astra_workflow_prompt_pilot.json`. Both arms Astra/high,
normal retained history, no experience. Four independent smoke cells followed by
54 pilot cells: eight coding scenarios and arithmetic, three repetitions each,
two arms, seed 909. Maximum 58 launches, $12 between-run cost threshold (may
overshoot by one run), 2400 active worker seconds. No retries. Frozen campaign:
`evals/results/20260905-astra-workflow-prompt/`.

Continue only for no per-scenario correctness loss, at least 15% lower aggregate
coding cost, lower median cost on five of eight coding scenarios, and no more
than 10% aggregate latency regression. Smoke/arithmetic excluded from that
comparison. A promising pilot earns held-out validation, not a default change.

## Offline validity and cohort limitations

Independent Lua/Python prompt transforms agree on the real prompt, preserving
project instructions even when they repeat an ablated line. Missing/duplicated
rules fail closed. Activation tests reject incorrect outgoing prompts.

All eight coding graders have known-good and known-bad checks before launch.
The current graders accepted copied saved successful artifacts for six tasks:
existing_codebase_edit (20260824T051731Z, codex_cli_sol-2), repeated_text_edit
(20260822T044247Z, exact-1), ambiguous_bug_investigation (20260905T044455Z,
normal-1), environment_recovery (20260822T101703Z, lca_sol-2),
stable_verification_regression (20260905T044856Z, normal-1), and
multifile_order_cancellation (20260905T044831Z, normal-1). Originals were not
modified. Dedicated unit tests establish positive and negative context-boundary
and injected-failure cases; noop checks cover all eight coding scenarios.

The cohort includes multi-file implementation, injected and environmental
failures, corrected conversational instructions, and narrow edit controls.
Saved baselines are mostly below 20 tool operations. This is a mixed screening
cohort, not long-task architectural evidence. Some original graders check trace
requirements as well as artifacts; report those separately. Existing rubric
limitations are retained symmetrically, not relaxed after seeing outcomes.

## V1 validity stop

V1 was stopped after nine completed runs and one interrupted run. The original
grader reports eight passes and one failure, but the failure is not an agent
defect: `cell-0007` implemented correct cancellation behavior and added
`tests/test_cancellation.py`. The task forbids modifying existing tests, not
adding tests, while the grader rejects all added files. Both public and hidden
behavioral gates passed. Offline positive/negative checks did not catch this
task-contract ambiguity; treating the scope rejection as a prompt regression
would be invalid.

Known completed-run estimated cost is $1.659254. `cell-0009` was interrupted
during a provider request, so total cost is higher by an unknown amount; its
request/response evidence is preserved, not counted as zero or retried. The
runner's generic missing-result halt is a consequence of that explicit stop.
No speed conclusion or default change follows from V1.

The interrupted cell preserved one complete response (7,042 input tokens,
3,712 cached, 18 output): $0.037912 standard-equivalent. Thus known total usage
is at least $1.697166, plus the unfinished second request. This supplement does
not overwrite the original campaign accounting.

## V2 registration

Fresh theory `astra_workflow_prompt_pilot_v2`, seed 910, same matrix and decision
rule, with explicit file-scope suffixes for all eight coding tasks. Both arms
receive the same clarified task. Original scenario files, graders and V1 results
remain untouched. The suffixes are frozen and independently checked against the
outgoing request. Campaign directory:
`evals/results/20260905-astra-workflow-prompt-v2/`. Do not pool V1 and V2.

The campaign runner now supports a tested graceful stop between runs, avoiding
loss of in-flight usage for subsequent operator-requested stops.

## V2 evaluator review identified during collection

`cell-0010` (current prompt, ambiguous investigation) passes all artifact gates
but is labeled a verification failure. Its final run contains the documented
unittest command, `Ran 3 tests ... OK`, and a successful focused cache probe;
only the trailing `git diff` fails because fixtures have no Git metadata. This
is an evaluator false negative, not missing verification. The cancellation
grader already handles this family of compound-command evidence; the ambiguous
investigation grader does not.

Continue V2 data collection with frozen sources and retain original grades.
Before deciding, implement a narrowly tested evidence correction and regrade
every affected cell in both arms, writing separate reviewed results. Preserve
the original registered outcome alongside corrected artifact/end-to-end counts;
do not call a raw-grade failure a model regression or relax the task contract.
The queued reasoning campaign has a graceful stop request so it cannot spend
money before this evaluator repair and a new source-frozen registration.

## V2 stopped for a higher-priority deterministic tool defect

Stopped gracefully after 21 complete runs, $3.763998 estimated cost and 755.17
active seconds. All raw
evidence is retained; no run was interrupted. This is an incomplete prompt
screen, not acceptance or rejection of workflow-lite.

Inspection of current-prompt `cell-0016` exposed a reproducible serialization
bug: a native single-line edit adds an unrelated trailing newline. Astra then
spent extra verification and repair calls restoring exact bytes. The run took
85.6 seconds, nine model calls and ten tools. The line splitter retains the
terminal empty segment and both tagged writers added another newline after
joining it. Prioritize fixing that deterministic defect over completing a
speculative prompt screen. It affects both arms equally but can provoke costly
recovery behavior.

The verification checker now accepts a documented green unittest summary before
an unrelated Git-metadata failure, but rejects failed tests, missing test output
and Python tracebacks. All affected ambiguous-investigation cells in both V1
and V2 were regraded on temporary copies, across both prompt arms, into separate
`result-reviewed-verification.json` files. Original artifacts, grades and metrics
were preserved. V2's reviewed count is 21/21, but the incomplete matrix still
supports no prompt-selection conclusion.
