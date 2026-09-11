# File-tool shell ablation — September 9, 2026

**Current status (September 9): fully rolled back at the user's request.** The results below are historical; the grader changes mentioned as retained below were also reverted. Registration now resides in `research/archive/20260909-file-tools-screen/astra_file_tools_screen.json`. See `research/decisions/2026-09-09-shell-tools-rollback.md`.
**Decision: drop this treatment.** All six runs passed artifact and activation checks, but the smaller coding task exceeded the registered 20% latency ceiling. This is a one-run-per-cell screen, not a general rejection of shell-based harnesses. No production defaults changed.

## Paired results

| Task | Native time | Shell time | Time change | Native cost | Shell cost | Cost change | Native / shell tool calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| simple_prompt | 2.96s | 3.49s | +17.9% | $0.02784 | $0.02504 | -10.1% | 0 / 0 |
| existing_codebase_edit | 28.79s | 35.25s | +22.4% | $0.13151 | $0.14691 | +11.7% | 10 / 4 |
| multifile_order_cancellation | 54.93s | 61.72s | +12.4% | $0.25852 | $0.29404 | +13.7% | 14 / 4 |

Total standard-equivalent estimated cost: $0.883852; active worker time: 187.97s. All six attempts completed; no missing or interrupted attempts. This is estimated token cost, not actual invoiced OAuth spend.

## Interpretation and limits

The treatment removed file-tool declarations and translated eight interface-dependent prompt passages. Job tools, planning, execution supervision, model (GPT-6 Astra/high), fixtures, and non-interface instructions were preserved. Both arms omitted hosted search and prohibited external services, added files, and background file writers. Both required a separate final verification command.

Fewer tool calls did not imply less work: shell calls bundled file reads and scripted replacements. Full command bodies and failures are preserved in raw trajectories; the analysis records tool/error counts, model calls, prompt/output/cache tokens, and paired effects. This screen does not measure net code savings, long-task reliability, process orchestration, subagents, or safety equivalence. Local observations motivated a feasibility question, not proof that native tools wasted work. Small and layered existing fixtures were reused, rather than a new adversarial decoy fixture.

Filesystem evidence captures complete text files at completed-tool boundaries, excluding caches and Git metadata. It is not an OS audit of transient writes, symlinks, or work outside the fixture. Hidden tests and final scope checks grade artifacts independently of assistant claims. Original trajectories and grades were not overwritten.

## Evidence and cleanup

- Registration: `evals/theories/astra_file_tools_screen.json` (historical, now rejected by active runners).
- Campaign: `evals/results/20260909-file-tools-screen/manifest.json`, `state.json`, `analysis.json`, and six `cell-*` directories with raw provider requests/responses, snapshots, workspaces, and original grades.
- Exact tested source: `evals/results/20260909-file-tools-screen/frozen-source.tar.gz`; fingerprint and source-log provenance are preserved alongside it.
- Offline grader preflight: `evals/results/20260909-file-tools-preflight/summary.json` and 20 positive/negative original grade records using both vocabularies.
- Rejected implementation and its tests: `research/archive/20260909-file-tools-screen/`. Eval driver and Python runner explicitly reject the retired option; campaign planning has no activation contract for it.
- Retained only the tool-neutral mutation-evidence normalizer, its regression tests, and the multi-file grader correction requiring verification after the **last**, rather than first, mutation.

Before live work, the local install, narrow intervention tests, full Lua/Python test suite, and 20 full-grader positive/negative checks passed. The campaign also ran its full offline preflight and audited every serialized outgoing request. Post-cleanup verification is recorded separately in `cleanup-verification.log` in the campaign directory.
