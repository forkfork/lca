# Shell primitives experiments: no demonstrated benefit; full rollback

Date: September 9, 2026

## Decision

At the user's request, roll back all implementation, eval-runner, grader, and test changes from both shell-tool experiments. Keep research notes, archived registrations/implementations, and original run evidence. No candidate remains active and no further runs are scheduled.

## What we learned

The original suggestion was that shell primitives might replace specialized harness machinery. We tested file access and discovery, not subagents or complete shell-only process orchestration.

| Experiment | Correctness | Coding time versus native tools | Estimated cost versus native tools | Interpretation |
|---|---|---|---|---|
| Shell for all file operations; two coding pairs plus simple control | 6/6 runs passed | +22.4%, +12.4% | +11.7%, +13.7% | Failed the registered 20% latency ceiling on the smaller task |
| Shell discovery only, native tagged reads/edits; one fresh coding pair plus simple control | 4/4 runs passed | −4.8% (about 1.7 seconds) | +3.7% | Within the feasibility threshold, not evidence of improvement |

Fewer tool calls did not reliably reduce model rounds, latency, or cost. The narrower intervention's small timing difference could be noise. Neither screen established maintenance savings or justified deleting production tools. The full ablation remains rejected; the narrower screen is parked rather than adopted. Do not pool these different interventions or interpret passing correctness as a performance win.

Ten completed runs cost approximately **$1.308162** in standard-equivalent estimated token usage, not actual invoiced OAuth spend. Original failed tool calls and cache usage remain included. These tiny screens cannot establish long-task reliability, safety equivalence, or general architectural superiority.

## Rollback and preserved evidence

- Restore the seven modified tracked files to their pre-experiment versions: campaign runner, Lua driver, Python runner, two graders, verification-evidence helper, and its tests. This includes reverting the useful-but-out-of-scope grader fixes, as requested by “all.”
- Remove discovery-ablation modules/tests and both registrations from active eval paths; archive them under `research/archive/20260909-discovery-tools-screen/` and `research/archive/20260909-file-tools-screen/`.
- Preserve the exact pre-rollback diff in `research/archive/20260909-discovery-tools-screen/pre-rollback.patch`.
- Keep the original decisions as historical records with explicit rollback notices.
- Keep original manifests, raw requests/responses, trajectories, metrics, grades, workspaces, and frozen source archives under `evals/results/20260909-file-tools-screen/` and `evals/results/20260909-discovery-tools-screen/`. Historical regrading/replay must use the corresponding frozen source, not the restored graders.

The practical recommendation is to keep LCA's existing tools. A future revisit should start from a concrete observed bottleneck and independently measured maintenance savings, not tool-count reduction alone.
