# LCA continuation notes

Last updated: 2026-08-22

## Objective

Make LCA with GPT-5.6 Sol a genuinely excellent daily coding agent. Optimize the
agentic path—correct decisions, useful repository understanding, coherent edits,
verification, recovery, latency, and cost—not isolated prose quality or arbitrary
tool-count scores.

The current evidence says LCA is credible and often competitive with Codex. It is
not yet justified to claim general superiority. On the calibrated scenarios it now
matches Codex's deterministic correctness; differences are mainly trajectory shape,
latency, and cost.

## Working method

Continue iteratively:

1. Start from an observed repeated trajectory problem in `/tmp/lca/logs` or a saved
   eval result, not a plausible-sounding prompt idea.
2. Turn the proposed explanation into a falsifiable theory under `evals/theories/`.
3. Separate hard outcome, evidence, scope, and safety gates from efficiency metrics.
4. Pilot once and inspect the raw trajectory. Do not trust the aggregate score before
   checking whether the grader handles both LCA and Codex event vocabularies.
5. Run at least three repetitions per cell for an optimization and usually five for
   a correctness boundary. Include a smaller negative control.
6. Adopt only the smallest treatment that preserves deterministic correctness and
   meets a predeclared efficiency threshold.
7. Run the narrow test first, then `make check` for shared Lua behavior. Record the
   result and honest tradeoffs in `research/experiments.md` and `research/decisions/`.

Codex is a reference, not an oracle. Compare final behavior, scope, evidence, and
wall time. Raw `llm_calls`, tool counts, and prompt-token totals are not directly
equivalent because Codex exposes one long invocation and often bundles many shell
operations, while LCA exposes each provider round and native tool call.

## Current production behavior

- GPT-5.6 Sol defaults to native function tools; XML remains an explicit fallback.
- Provider continuation replays native calls, results, and reasoning items.
- Sol requests use cache-affinity identifiers and priority service tier by default.
- The system prompt includes a compact startup executable inventory. It scans `PATH`
  in-process without launching programs or querying versions. The deliberately narrow
  list covers shell/Git/Make, Python, Lua, Node package tools, Go, and Rust; it excludes
  Ruby, JVM tooling, Bun, Deno, Docker, and speculative ecosystems.
- The prompt includes the tested evidence-sufficiency rule: stop duplicate checking
  once distinct evidence resolves the active uncertainty, while expanding when a
  failure reproduces or source evidence conflicts.
- The wholly read-only core batch cap is now 6. General batches remain capped at 10;
  mutation dependency rules, the 24 KB aggregate read budget, read-loop guard, and
  40-tool turn budget remain intact.
- The prompt version is 15, so older saved sessions rebuild the frozen prompt once.
- Web search support and Codex OAuth-backed search were implemented earlier; they are
  not the current optimization focus.
- Tagged edits now recover safely from pure line drift caused by an earlier insertion
  or deletion: both unchanged endpoint tags must relocate uniquely by the same bounded
  offset. Changed or ambiguous content still fails stale.
- A transactional `multi_edit` implementation and eval intervention exist, but its
  schema is disabled in production by default because the broad adoption threshold
  was not met.

## Strongest recent evidence

### Evidence sufficiency

The treatment was effectively correct in 30/30 trajectories. One raw control failure
was an audited grader vocabulary false negative; treatment itself was raw 15/15.

- Transient failure: tools 13.0 -> 7.0, verification 5.6 -> 2.8, latency 30.8s ->
  15.9s, estimated cost $0.0911 -> $0.0543.
- Stable regression: tools 10.8 -> 8.0, verification 2.8 -> 2.0, latency 29.5s ->
  20.1s.
- Existing edit retained exactly one verification in both cells.

See `research/decisions/2026-08-22-evidence-sufficiency.md`.

### Realistic multi-file feature

`evals/scenarios/multifile_order_cancellation/` is the current whole-loop benchmark.
It requires understanding and changing model, repository/service, and JSON API
behavior while preserving shipping, querying, imports, error shapes, idempotency,
audit ownership, and scope. It has public and hidden tests and requires architectural
inspection before mutation plus successful post-edit verification.

After calibrating ambiguous whitespace wording and compound-command verification:

| Engine | Passes | Mean latency | Mean prompt tokens | Mean estimated cost |
| --- | ---: | ---: | ---: | ---: |
| LCA Sol | 3/3 | 59.4s | 90.2k | $0.1391 |
| Codex Sol | 3/3 | 48.6s | 106.6k | $0.1487 |

Correctness tied. Codex was about 10.8 seconds faster; LCA used fewer prompt tokens
and was slightly cheaper. Do not use the raw one-turn Codex versus 8-11-turn LCA
shape as a direct score.

See `research/decisions/2026-08-22-multifile-order-cancellation-baseline.md`.

### Read-only discovery cap

The first multi-file baseline showed LCA requesting seven independent reads on every
run. Cap 5 deferred both tests and public imports. Cap 6 admits the test file but
still defers the lower-value `orders/__init__.py`, preserving an inventory boundary.

| Read cap | Passes | Mean tools | Mean model calls | Mean latency | Mean prompt tokens | Mean cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | 3/3 | 14.7 | 9.0 | 61.8s | 93.6k | $0.1501 |
| 6 | 3/3 | 13.7 | 7.0 | 50.2s | 70.9k | $0.1349 |

Negative controls:

- Existing edit: 3/3 in both variants, exactly four model calls and one verification.
  Cap 6 admitted one extra read and was 8.5% slower (27.8s versus 25.6s).
- Simple prompt: 3/3 in both variants, one model call and zero tools.

The production default was changed to 6. `make check` passed, and a fresh installed
default multi-file run scored 100 with seven model calls and one verification.

See `research/decisions/2026-08-22-read-only-discovery-cap.md`.

### Environment handling

Environmental failures were a real repeated source of wasted turns. The runtime
inventory eliminated all bare-`python` attempts in five post-treatment transient
runs while preserving correctness. Paired credential, port-ownership, missing-runtime,
transient-failure, and stable-regression scenarios all distinguish external blockers
from application defects. Keep these as regression controls for future loop changes.

## Important grader lessons

- Never grade a whole compound shell command as failed merely because its final
  `git status`/`git diff` subcommand failed in a non-Git temp workspace. Preserve
  earlier explicit green test/diagnostic evidence.
- Equivalent Codex `command_execution`/`file_change` and LCA native events must receive
  equivalent semantic credit.
- Final-answer phrase lists create false negatives. Add regression cases for observed
  valid paraphrases, but do not loosen mutation/safety gates.
- Hidden requirements must be entailed by the visible contract. The multi-file eval
  now explicitly says trimmed request IDs are stored and compared in normalized form.
- Preserve failed and misleading trajectories. They are evidence about the harness
  even when they are not evidence about the agent.

## Recommended next work

### 1. Conditional multi-hunk tool promotion

The transactional interface itself is implemented and mechanically safe, but always
advertising it did not meet the broad efficiency threshold. Test a promotion policy
that exposes it only after inspection establishes multiple independent same-file
replacements, without adding a model-only decision round.

Use at least:

- `existing_codebase_edit`
- `repeated_text_edit`
- `stale_edit_recovery`
- `multifile_order_cancellation`

Keep the existing hard gates and use `multi_location_edit` as the positive
discriminator. Preserve `existing_codebase_edit`, `repeated_text_edit`,
`stale_edit_recovery`, and `multifile_order_cancellation` as controls. See
`research/decisions/2026-08-23-transactional-multi-edit.md`.

### 2. Necessary-versus-redundant trajectory labels

Add an analysis rubric that labels actions as necessary, useful defense-in-depth,
redundant, or recovery. This should remain diagnostic until calibrated against human
labels. It is more useful than penalizing raw tool count, especially on authentication
and ambiguous-failure tasks.

Use it to identify the next repeated causal inefficiency after the read-cap change.
Likely candidates are standalone plan updates and avoidable post-edit inspection, but
do not blindly remove plans: the existing `sol_plan_overhead` pilot found that hiding
`update_plan` did not reduce total rounds on the broad auth task.

### 3. Another realistic whole-loop path

Add an underspecified bug or refactor where the agent must discover the defect and
choose its own test strategy. The current multi-file feature is realistic but has a
clear written contract. Useful missing coverage includes:

- vague bug report with multiple plausible causes;
- multi-file refactor preserving backwards compatibility;
- dependency/API integration requiring current research;
- test-authoring quality rather than only satisfying existing tests;
- interrupted/resumed work with a concise handoff.

### 4. Long-session/compaction continuity, later

The concern is valid, but these evals are expensive. Do not start with a giant blind
context test. Build a shorter deterministic continuity fixture first: establish a
goal and several decisions, force one compaction boundary, then require a later edit
to honor an early constraint. Measure correctness and lost/repeated work. Only expand
to long real sessions if that fixture discriminates.

### 5. Networking migration remains separate

There is interest in moving from `luv` networking to the custom `cqueues`/`luaossl`
fork. Do not mix that migration with agent-loop optimization. First freeze transport
contract tests for streaming, cancellation, first-byte/idle/absolute deadlines,
WebSocket continuation, TLS failures, and shutdown. Then compare implementations
behind the same provider interface.

Programmatic Tool Calling is also deferred. Existing implementation trajectories
alternate judgment, mutations, and verification; direct native calls fit them better.
Revisit PTC only with a read-heavy scenario whose results can be mechanically reduced.

## Commands and locations

```bash
# Required after changing Lua source, scripts, bins, or rockspecs
make local

# Narrow tests first, then the full gate for shared behavior
lua tests/test_core_sanitization.lua
python3 -m unittest discover -s evals/tests -p 'test_*.py' -v
make check

# Current realistic scenario
python3 evals/run.py multifile_order_cancellation \
  --model gpt-5.6-sol --reasoning low --runs 1 --keep

# Reproduce the read-cap theory
python3 evals/run.py multifile_order_cancellation \
  --theory read_only_discovery_cap --reasoning low --runs 3 --seed 934

# Cross-agent comparison for one scenario
python3 evals/run.py multifile_order_cancellation \
  --theory agent_loop_sol_comparison --reasoning low --runs 3 --seed 935
```

- LCA runtime logs: `/tmp/lca/logs/lca-*.log`
- Saved eval trajectories/results: `evals/results/`
- Experiment register: `research/experiments.md`
- Decisions: `research/decisions/`
- Research sources and IDs: `research/sources.json`
- Architecture: `docs/architecture.md`

When debugging a bad run, start from the matching timestamped LCA log and the saved
`trajectory.json`, `transcript.log`, `grade.json`, and kept workspace. Replay parser
edge cases from captured raw text where possible.

## Repository state and handoff warning

The worktree currently contains a large, intentionally accumulated set of modified
and untracked files spanning runtime changes, eval infrastructure, research, tests,
and documentation. These changes are not isolated to the last optimization. Do not
reset or discard them. Before starting another large feature, review the diff and make
a deliberate checkpoint commit (or split it into coherent commits) so later
experiments have a stable base.

At the end of this session, `make check` was green and the installed local rock
matched the checkout. The latest production smoke was also green.
