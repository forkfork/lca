# From hypothesis to decision

AGENTS.md carries the invariants; this document defines the workflow.

## River → log → hypothesis → eval

1. **Inspect a concrete turn.** Use `/river` to identify the calls behind a
   failure, overlap, or repeat. Find the matching `/tmp/lca/logs/lca-*.log` and
   inspect raw requests/results around those calls. Record the log path and call
   references. A failed test may be useful; a reread after an edit may be needed.
2. **Write the causal claim.** State the observed problem, why it happens, the
   smallest harness change that could fix it, and what result would falsify the
   explanation. External research is optional; local evidence can supply the idea.
3. **Register before running.** Freeze the intervention, control, tasks, model,
   reasoning, prompt, source/fixture/grader hashes, seed, budgets, primary metric,
   and reject/advance rule. Change only the registered factor within each pair.
4. **Check validity cheaply.** Test graders with known-good and known-bad artifacts;
   check the intervention locally and audit actual outgoing requests. For a screen,
   the first registered cells supply live activation checks—do not add a separate
   paid pilot. Stop an invalid treatment and register a new version after fixing it.
5. **Run a small screen.** Two arms × `simple_prompt` plus one or two coding tasks,
   one run per cell: **4–6 total runs**, or two to three matched pairs. Randomize
   adjacent-pair arm order. A useful signal buys fresh validation, not adoption.
6. **Decide and clean up.** Record results, failures, limitations, and the decision
   in `research/decisions/`. Drop a failed implementation; advance a promising one
   to fresh broader validation; adopt only after its registered validation gates
   pass. Remove rejected runtime branches and flags. Keep frozen source and raw
   evidence outside active runtime paths, rather than leaving dormant features.

Example hypothesis: “Search results omit edit tags, forcing an extra read before
editing. Returning tags should eliminate that read while preserving correct edits.”
Check that tags actually reach the model and edits use them. Use independently
graded coding tasks plus a simple control. A predeclared gate could require all
correctness checks to pass, fewer read calls on target tasks, and no more than a
specified time/cost regression. Choose the tolerance before seeing results.

### Metrics to report together

- **Correctness:** external artifact grade, protocol/activation validity, and
  required verification. Do not count an early abort as an efficiency gain.
- **Calls:** tool operations and model calls separately; include per-tool counts
  and the mechanism-specific events (for example, rereads or stale-edit retries).
  One shell call can contain many commands; batching does not necessarily reduce
  work. Check the actual commands and outcomes.
- **Time:** end-to-end elapsed time as the efficiency outcome. River “time in tools”
  measures the union of foreground tool intervals, excluding model-only gaps and
  unobserved background-job lifetime; it is a diagnostic, not task latency.
- **Resources:** input/output tokens, cache use, and estimated cost for every
  attempt, including failures. State missing usage and pricing exclusions.

Show control/treatment values and paired differences per task, not only a pooled
average. Explain whether the hypothesized behavior changed. Call counts alone
cannot establish that a harness became better.

The optional [EXPLORATION.md](EXPLORATION.md) ledger is a separate eval-side
experiment for testing retained lessons. It is not required for ordinary harness
changes and does not run automatically in the product.

## Campaign runner

### Fast exploration is the default

Use `study_kind: screen` to try a new idea cheaply: exactly two arms, one run per
arm on `simple_prompt` and one or two coding tasks (4–6 runs total). The simple
control runs first; coding task order and adjacent-pair arm order are randomized.
Screen runs replace separate smoke/pilot repetitions and stop on a failed task
or activation check. The manifest records `decision_scope: screen_only`.

Predeclare a small spend/time budget and an advance/drop rule. A positive screen
buys another experiment, never a default change. Replicate a promising signal on
fresh tasks before paying for a larger cohort. Keep correctness, actual-request
audits, failed-run accounting and the cheap Python preflight. Run narrow local
tests during implementation; run the full suite for shared-code changes, not
merely because another unchanged model trial is being launched. Long coding
cohorts remain necessary for architectural or promotion claims, not every idea.

Example: `astra_workflow_fast_screen` has six runs, a $1.75 estimated-cost
threshold and a 360-active-second deadline. Deadlines are hard runtime limits,
not promises about latency or exact billing. A timed-out request may have unknown
final usage and must remain reported as such.

`campaign.py` implements a first, deliberately serial campaign runner. Planning
makes no model calls. It freezes the theory, randomized smoke-first matrix,
budgets, and source/fixture/grader content fingerprint into an immutable manifest.
Explicitly pinned model/reasoning, context-mode, and frozen experience variants are supported;
unknown switches fail validation until an activation checker is implemented.

The nine-line `workflow-lite` prompt deletion was dropped after its fresh-task
replication failed the speed gates. Its implementation is archived and the old
profile fails before workspace creation or model calls. Historical manifests
and evidence remain readable. `prompt_profiles.py` audits the current prompt
only; retired prompt experiments have no runtime switch. See `research/decisions/2026-09-06-workflow-prompt-final.md`.

The planning clarification now lives in the normal production prompt by explicit
user decision after its positive screen. Its old `planning-clarity` profile is
retired to prevent accidentally comparing identical arms. The unsupported cache
options probe is archived too; see `research/archive/README.md`. Historical
registrations and original results remain unchanged.

The hosted-search ablation supports `tool_scope: all|local_only` in normal
history. `local_only` removes only the hosted `web_search` declaration, not
native tools or prompt instructions, and is not a network sandbox. The context
recorder now captures actual serialized provider bodies; `tool_scope.py` checks
every payload against a frozen native-tool baseline. Production browsing stays
unchanged. Use only explicitly offline scenarios for this causal comparison.

The rejected repository-facts probe and obsolete lean/minimal prompt transforms
are archived and cannot be executed by the current runner. Historical manifests
and raw results remain intact; see `research/archive/README.md`.

Theories may freeze `task_suffixes` by scenario to clarify a task contract without
rewriting historical fixtures. Each suffix applies identically to every arm and
is checked in the first outgoing request. Use `campaign.py stop DIRECTORY` to
request a durable stop after the in-flight run; it preserves complete usage and
artifacts and does not retry or resume a halted campaign.

```bash
# Example matrix only: the old state-only implementation remains rejected.
python3 evals/campaign.py plan evals/results/state-pilot-plan \
  --theory state_only_pilot --seed 906 --max-runs 60 --max-cost 5 --max-seconds 1800
python3 evals/campaign.py status evals/results/state-pilot-plan
# Running/resuming is explicit and may spend money:
# python3 evals/campaign.py run evals/results/state-pilot-plan
```

For non-screen campaigns, the first repetition of each smoke scenario/arm is a separate smoke stage, not
a replacement pilot repetition. Default smoke scenarios are simple_prompt and
ambiguous_bug_investigation; both must occur in the theory. All smoke task and
protocol checks must pass before any pilot cell launches. Pilot task failures
remain measured outcomes; protocol/activation failures halt either stage.

Before paid work, Python eval tests run as offline preflight. This checks existing
grader contracts, not whether every scenario already has complete positive and
negative coverage; review/add those tests before approving a new theory.
Model/reasoning/context mode are checked in the captured outgoing requests.
State-only also uses the request-isolation audit. Evidence lives in each durable
`cell-NNNN` directory; `state.json` records completed cells and accumulated cost
and active worker time. A lock prevents concurrent controllers for one campaign.

Run-count limits are hard launch limits. Cost is a **between-run standard API
estimate threshold**, can overshoot by one run, and is not a billing cap.
Active worker time is bounded by terminating the worker process group at the
remaining deadline; offline preflight is outside that budget. Unknown/partial
usage stops the campaign for review. Completed cells are never rerun. A halted
or interrupted campaign requires review/new registration; there is intentionally
no automatic retry or unsafe “clear running” switch. Source or manifest drift
also requires a new campaign. Budget-limited/incomplete runs exit nonzero.

A theory may explicitly declare `study_kind: calibration` for exactly one
baseline variant. It characterizes workload behavior and cannot establish a
causal improvement. Ordinary comparisons still require at least two variants.

Compatibility and crash-safety tests use fake workers, with no paid model calls.
This runner does not approve hypotheses automatically or supply statistical
power. Existing analysis tools and a recorded decision are still required.

## Campaign contract

Before spending on a campaign, register a theory under `evals/theories/` using
the existing schema and validation described in `evals/theories/README.md`.
Include the mechanism, implemented switch, expected request-level difference,
external success criteria, task cohort, paired controls, repetitions, randomized
order/seed, maximum runs and spend/time limits, and reject/continue rules.
Pin the model and reasoning explicitly. Preserve the existing historical Sol
default rather than silently turning old theories into Astra experiments.

Use three gates:

1. **Offline validity:** grader positive/negative contract tests; intervention
   unit tests; assertions that the intended information is present/absent.
   Check that every hard gate matches the task's stated contract. For example,
   “do not modify existing tests” does not unambiguously forbid new test files;
   the Astra migration smoke exposed precisely that mismatch.
2. **Live activation:** for screens, use the registered first cells as above.
   For larger campaigns, run one small control and one representative coding run per arm.
   A broken protocol is an invalid treatment. Diagnose it before scaling; a
   repaired treatment starts a new campaign/version, not a replacement cell.
3. **Paired pilot, then long cohort:** run the registered pilot before funding
   20–50 long tasks. Select long tasks by baseline behavior (20+ tool operations,
   multiple files, failed approaches, revisited assumptions), not by a treatment
   becoming stuck. Include simple controls to detect overhead regressions.

Report external artifact correctness and end-to-end correctness separately.
Include every attempted run in resource accounting and classify transport,
protocol, grader, environment, and coding failures. Repeated read candidates
require manual context review: a reread after an edit is not necessarily waste.
Define stale-belief failures with evidence references and a reviewer rubric;
do not treat free-form model self-reports as ground truth.

## Next infrastructure, in order

1. Extend the serial campaign runner with additional intervention contracts,
   coverage for every grader, and reviewed recovery of interrupted evidence.
   Parallel execution and hard per-request billing controls remain unimplemented.
2. A common evidence format: exact outgoing requests, raw incoming responses,
   tool observations, repository revision at each mutation, per-call usage,
   protocol status, and artifact grade. Generalize the state pilot's tracing
   rather than maintaining a different analyzer for every hypothesis.
3. Common reviewed grading and reports: preserve original grades, regrade frozen
   artifacts symmetrically, summarize paired effects and uncertainty. River
   observations identify questions; controlled evaluations provide adoption evidence.
4. A genuinely long coding cohort with hidden regression tests, constrained
   scope, and explicit recovery/revision requirements.

## State/history experiments

The later ledger-eviction screen also rejected its implementation: source packing
dropped requirements and increased repeated work. Consult both the
[ledger decision](../research/decisions/2026-09-06-ledger-eviction-screen.md) and
the earlier state-only decision before designing a fresh comparison. The ideas
below remain hypotheses, not demonstrated improvements.

Do not rerun the rejected prompt-only protocol unchanged. Try a harness-owned
state ledger: immutable task/constraints, verified completed facts tied to repo
revisions, separate tentative beliefs, append-only rejected approaches, exact
verification commands/results, and retrievable evidence IDs. Accept validated
state deltas transactionally; retain the previous state on invalid updates.
Define update boundaries around task progress rather than every standalone
plan/tool response. Keep observations until consumed by a committed transition.

Compare normal Astra, ledger plus history, and ledger without history on the
same frozen Astra baseline. This distinguishes the value of explicit state
from the effect of removing history. Never mix this with a model/prompt upgrade
in the same causal contrast. See the
[pilot decision](../research/decisions/2026-09-05-state-only-pilot.md).
