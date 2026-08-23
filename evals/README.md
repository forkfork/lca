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
- the research source IDs that generated the idea;
- one control and one or more variants that change a harness variable;
- positive scenarios and negative controls;
- deterministic outcomes, efficiency outcomes, minimum sample size, and a decision
  rule written before results are collected.

Run the system-prompt minimalism experiment with its declared minimum of five runs
per scenario/variant:

```bash
python3 evals/run.py --theory system_prompt_diet
```

For a smoke run or one side of the experiment:

```bash
python3 evals/run.py --theory system_prompt_diet --runs 1
python3 evals/run.py --theory system_prompt_diet --variant minimal --runs 1
python3 evals/run.py existing_codebase_edit --theory edit_tool_exact_vs_tagged
python3 evals/run.py --theory edit_tool_resilience
python3 evals/run.py --theory stream_duplicate_call_cap
python3 evals/run.py --theory intra_turn_context_reserve
python3 evals/run.py --theory fresh_orientation_context
python3 evals/run.py --theory orientation_model_5_6
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

## Rating policy

A scenario may define hard gates as well as a numeric score. A run that violates a
hard gate fails even if it earns points elsewhere. Report per-dimension scores and
raw evidence; do not optimize against a single opaque total.

For model comparisons, use at least five runs per scenario, report pass rate and
the distribution of scores/tool counts, and keep the scenario, grader, prompt,
model, and reasoning effort fixed. Review judge disagreements before changing a
system prompt.
