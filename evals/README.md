# LCA agent evaluations

These are end-to-end evaluations of LCA's agentic behavior. They are deliberately
separate from `make test`: evals call a live model, cost money, and are stochastic.

## Design

LCA is normally the system under test. `run.py` creates a fresh workspace, runs one
agent turn, captures its final answer and complete tool trajectory, and then grades
the workspace and trajectory from outside the agent. Registered reference theories
may use the normalized Codex CLI driver against the identical fixture.

Scoring has two layers:

1. Deterministic graders own pass/fail. They check exact answers, executable
   behavior, security invariants, and observable trajectory properties.
2. An optional independent Codex judge rates qualitative properties that cannot
   be reduced to a stable test. Its score is reported separately and is not mixed
   into the deterministic score until it has been calibrated against human labels.

LCA must not grade itself. A self-score would reward persuasive final answers and
shared blind spots instead of the actual result. Codex is useful as an independent
judge, but it should not manually drive the LCA session or replace hidden tests.

## Running

List scenarios:

```bash
make eval-list
```

Run one scenario once:

```bash
python3 evals/run.py simple_prompt
python3 evals/run.py auth_api
python3 evals/run.py existing_codebase_edit
python3 evals/run.py repeated_text_edit
python3 evals/run.py stale_edit_recovery
python3 evals/run.py context_boundary_edit
python3 evals/run.py failure_recovery
python3 evals/run.py ambiguous_bug_investigation
python3 evals/run.py credential_blocker
python3 evals/run.py credential_loader_bug
python3 evals/run.py environment_recovery
python3 evals/run.py port_conflict_external
python3 evals/run.py port_loader_bug
python3 evals/run.py transient_verification_failure
python3 evals/run.py stable_verification_regression
python3 evals/run.py project_orientation
```

Run a small stochastic sample and retain workspaces:

```bash
python3 evals/run.py auth_api --runs 5 --keep
```

Add an independent Codex rating:

```bash
python3 evals/run.py auth_api --judge codex
```

Use `--credentials`, `--model`, and `--reasoning` to pin the system under test.
Results are written under `evals/results/`, which is ignored by git.

## Testing research theories

A theory is an executable controlled experiment in `evals/theories/`. It must state:

- the falsifiable hypothesis and what result would falsify it;
- the local trace references or research source IDs that generated the idea;
- one control and one or more variants that change a harness variable;
- positive scenarios and negative controls;
- deterministic outcomes, efficiency outcomes, minimum sample size, and a decision
  rule written before results are collected.

Start with the [river → log → hypothesis → eval recipe](EXPERIMENTS.md#river--log--hypothesis--eval)
for new comparisons. A screen has 4–6 total runs: two arms, two or three scenarios,
one run per cell. Report correctness, tool/model calls, time, tokens, and cost together. Historical prompt-diet and exact-edit experiments are retired;
their manifests remain for interpreting saved evidence.

Examples of scenario comparisons:

```bash
python3 evals/run.py --theory edit_tool_resilience
python3 evals/run.py --theory intra_turn_context_reserve
python3 evals/run.py --theory fresh_orientation_context
python3 evals/run.py --theory orientation_model_tiers
python3 evals/run.py --theory orientation_agent_loop_baseline
python3 evals/run.py --theory orientation_5_6_grounding
python3 evals/run.py --theory environment_recovery_baseline
python3 evals/run.py --theory credential_boundary_baseline
python3 evals/run.py --theory port_ownership_baseline
python3 evals/run.py --theory verification_boundary_baseline
python3 evals/run.py --theory evidence_sufficiency
```

The theory runner reports one cell for every scenario/variant pair, including pass
rate, score, model/tool calls, elapsed time, prompt/output tokens, and cache use. A
research source is "useful" only if it produces a discriminating hypothesis and the
corresponding treatment survives this process. Popularity is not an outcome metric.
Theory jobs are interleaved in a seeded random order (`--seed`) to reduce time/provider
ordering effects. Every result stores `run-config.json` so the exact scenario, theory,
variant, model, reasoning setting, run number, and order seed survive later edits.
Registered theory runs also retain the final workspace and record SHA-256 digests for
the fixture and grader, so a later audit can regrade the actual artifact and identify
which cells used the same contract.

Run grader and manifest contract tests with:

```bash
python3 -m unittest discover -s evals/tests -p 'test_*.py'
```

## Explicit-state pilot

`python3 evals/run.py --theory state_only_pilot --seed 906` runs three
repetitions of six existing scenarios in normal, state-only, and state-plus-history
modes (54 runs). This pilot checks protocol viability and short-task overhead;
it does not validate the longer-task hypothesis. Production defaults are unchanged.

The eval-only `--context-mode` driver option installs core lifecycle callbacks.
Both state variants emit an 8,000-byte-bounded JSON state in the same response as
their next action. Missing or invalid state fails the run without executing that
response's tools; its usage and response are still retained. State-only preserves
original user messages (including corrections), current state, and the latest
tool batch with native call/output pairing, but drops prior assistant messages
and encrypted reasoning. State-plus-history keeps normal context management.

Each result directory retains `initial-context.json`, `request-NNNN.json`,
`response-NNNN.json`, `state-NNNN.json`, and retrievable `observation-NNNN.json`
files outside the graded workspace. Requests expose the exact model-facing
message fields for auditing. Trajectories include state-protocol counters and
all primary model-call usage, including rejected state responses. This pilot
does not force the synthetic context-boundary fixture through compaction;
it uses that fixture to test retention of authoritative user corrections.

`python3 evals/analyze_state_pilot.py --seed 906` audits every state-only request
against its original task, previous emitted state, and archived latest batch,
checks native call/output pairing and absence of provider reasoning, and reports
per-cell descriptive metrics. Identical source rereads are flagged for human
review, not automatically classified as investigation failures. Never interpret
an early protocol abort's lower cost as an efficiency improvement.

After an independently tested grader correction, `python3 evals/regrade_state_pilot.py
--seed 906` regrades the frozen workspaces without calling models. It writes
`artifact-grade.json` and `result-reviewed.json` alongside the original results,
records the new grader hash, and never converts a protocol failure into a pass.
The analyzer prefers reviewed results when present. The September 5 pilot needed
two corrections: symmetric exclusion of fixture bytecode caches in the correction
scenario, and acceptance of bold formatting around a correct arithmetic answer.

## Rating policy

A scenario may define hard gates as well as a numeric score. A run that violates a
hard gate fails even if it earns points elsewhere. Report per-dimension scores and
raw evidence; do not optimize against a single opaque total.

For model comparisons, use at least five runs per scenario, report pass rate and
the distribution of scores/tool counts, and keep the scenario, grader, prompt,
model, and reasoning effort fixed. Review judge disagreements before changing a
system prompt.

## Experiment workflow and Astra

Follow [EXPERIMENTS.md](EXPERIMENTS.md) for validity gates, campaign evidence,
and reject/continue decisions. LCA now defaults to Astra interactively, but this
runner retains Sol for historical unpinned theories. Select Astra explicitly:

```bash
python3 evals/run.py multifile_order_cancellation --model gpt-6-astra --reasoning high --runs 1 --keep
```

A variant's explicit model overrides the CLI model. New theories should pin
model and reasoning per variant. Astra costs are standard API-equivalent
estimates, with long-context pricing applied per request; they exclude service
tier and hosted-tool charges and do not describe Codex subscription billing.

### Cache-prefix audit

Inspect saved provider requests and usage without making model calls:

```bash
python3 evals/analyze_cache_prefix.py evals/results --output /tmp/lca-cache-audit.json
```

The report distinguishes preserved-prefix cache drops, request changes, recorded
object-order changes, and usage-counter mismatches. It does not assign backend
causes. New eval captures preserve serialized request bytes; older captures may
have been decoded and re-encoded. The unsupported live cache-options probe and
the promoted planning profile are archived; see `research/archive/README.md`.
