# Exploration ledger and promotion experiment

This is an eval-side experimental record, not production memory. LCA's normal
prompt and AGENTS.md are not rewritten when an observation or candidate is saved.
The first real imported record is the verification-loss case in the state-only
pilot. It is an observation, not promoted knowledge.

## Lifecycle

`exploration.py` stores hash-chained, append-only JSON events under a chosen
directory. It locks writers, rejects duplicate IDs, and checks captured evidence
hashes. Files are never edited in place. A corrupt/partial tail fails closed.
This is tamper detection for accidental changes, not a signed security ledger.

An observation contains `id`, `task_id`, `family`, `question`, `hypothesis`,
`intervention`, measured `observation`, `judgment`, `confidence`, and evidence.
Use `evidence_files` in an input JSON to capture JSON evidence artifacts with
their source paths, contents and hashes. Keep original run transcripts separately.
Record unsuccessful attempts too. There is no automatic attempt detector or
model-written promotion hook: import a record explicitly at a meaningful boundary.

A candidate references observation IDs and freezes the conditional `lesson`,
`condition`, comparable-task `family`, `metric`, exact `validation_tasks`,
separate `evaluation_tasks`, and a `rule`:

```json
{"direction":"lower","minimum_median_gain":0.10,"maximum_regression":0.05}
```

At least five distinct validation tasks must be registered **before** results
are appended. Task IDs cannot overlap discovery or held-out evaluation. A new
seed or a renamed copy of a fixture is not a new task; this semantic comparability
requires human review, beyond the ID checks. Register repetitions/noise handling
in the external evaluator and do not select favorable repeats afterwards.

Each validation captures an external paired evaluator artifact with:

```json
{
  "candidate":"candidate-id", "task_id":"validation-task-id", "family":"family-id",
  "metric":"elapsed_ms", "before":100, "after":79,
  "control_passed":true, "treatment_passed":true,
  "fixture_sha256":"...", "grader_sha256":"...",
  "model":"gpt-6-astra", "reasoning":"high",
  "control_run":"unique-control-run", "treatment_run":"unique-treatment-run"
}
```

The evaluator must hold fixture/model/reasoning/grader fixed within each pair
and change only the registered intervention. The ledger checks declared identity,
measurements, provenance fields, duplicates, and correctness booleans; it does
not independently execute or authenticate the evaluator. Never substitute an
assistant's “tests passed” claim for an external result.

Promotion requires the complete registered cohort, passing correctness on both
sides, sufficient median gain, and no regression beyond the registered bound.
Confidence is ignored. The promoted wording/condition must be exactly the frozen
candidate's, not a broader rewrite after seeing results. Rejected promotion leaves
the candidate intact and returns an error; it is not an additional lifecycle state.
The example gains +21%, +18%, +2%, -4%, +16% yield median +16% and pass the
example rule **in synthetic unit tests only**. This is not evidence for AST caching.

```bash
python3 evals/exploration.py LEDGER observation observation.json
python3 evals/exploration.py LEDGER candidate candidate.json
python3 evals/exploration.py LEDGER validation validation.json
python3 evals/exploration.py LEDGER assess candidate-id
python3 evals/exploration.py LEDGER promote candidate-id
python3 evals/exploration.py LEDGER export raw-trajectories.json --output evals/experience_corpora/promotion-v1.json
```

Export requires matched raw trajectories for exactly the discovery and validation
tasks (`[{"task_id":"...","trajectory":...}]`; include both paired runs in each
validation task entry). The output must be new; create its parent directory first.
The experiment corpus is deliberately absent until real cross-task validation
exists. Do not populate it with the synthetic unit-test records.

## A/B/C/D and independent interpretation

The `exploration_promotion` theory registers four fresh-session arms on the same
held-out tasks, model and reasoning: A empty experience; B matched raw trajectories;
C observations, candidates and validation measurements; D promoted conditional
lessons only. Primary contrast is D versus C. State/history handling is otherwise
unchanged. All experience enters as fallible user-role reference data before the
current task, never as a system instruction. Exact injected text and bundle hashes
are audited. Discovery/validation task reuse and an empty D arm block execution.
All views share a fixed 200KB limit; oversized views fail rather than truncate.

The registered short-task cohort is a proposed verification-policy pilot, not
appropriate evidence for arbitrary lessons such as AST caching. Review task-family
fit and grader contracts before collecting/exporting a real corpus. The current
pilot permits at most 44 runs (8 smoke + 36 pilot), a $10 between-run estimate
threshold, and 3600 active seconds. Use all three flags when planning. Report
discovery/validation costs separately and amortized; the held-out costs alone
are not the full lifecycle cost. No automated scientific approval is provided.

```bash
# Only after a real corpus exists and the held-out cohort is reviewed:
python3 evals/campaign.py plan evals/results/promotion-pilot \
  --theory exploration_promotion --smoke simple_prompt existing_codebase_edit \
  --seed 907 --max-runs 44 --max-cost 10 --max-seconds 3600
```

A D-over-C gain would support the complete filtering/promotion treatment, but
would not by itself separate validated content from shorter context. Report
experience bytes and token costs; a later length-matched control can distinguish
those mechanisms.

`review_exploration.py LEDGER OUTPUT` starts one fresh Astra/high LCA instance in
an empty workspace with tools disabled. Only question, intervention, measurements,
and evidence hashes are supplied: no hypothesis, judgment, confidence, candidate
or promotion text, original source paths, or evidence bodies. It cannot retrieve
the original conclusions through the supplied tools. This is an interpretation
check, not another validation task. Free-text measurements/questions still need
human review for semantic leakage and selective reporting. Same-model agreement
can reflect correlated biases and is never a promotion gate.

The first live check uses one selected real pilot observation and a predeclared
manual rubric: identify the record loss, keep any lesson conditional, and request
cross-task validation. One invocation, 180-second timeout, no extra run on failure.
