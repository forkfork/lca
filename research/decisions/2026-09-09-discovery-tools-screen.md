# Discovery-only shell screen — September 9, 2026

**Current status (September 9): fully rolled back at the user's request; further validation is not scheduled.** The decision below describes the historical screen, not an active candidate. Implementation and registration now reside in `research/archive/20260909-discovery-tools-screen/`. See `research/decisions/2026-09-09-shell-tools-rollback.md`.
**Decision: further validation, not adoption.** All four cells passed correctness and exact-request activation checks. The fresh coding pair met the registered 20% latency/cost ceilings with actual discovery use in both arms. This does not reverse the rejected full file-tool ablation.

## Results

| Task | Native time | Shell-discovery time | Native cost | Shell-discovery cost | Native / treatment tools | Native / treatment model calls |
|---|---:|---:|---:|---:|---:|---:|
| Simple prompt | 3.038s | 2.584s | $0.02785 | $0.02693 | 0 / 0 | 1 / 1 |
| Cache bug investigation | 34.588s | 32.928s | $0.18142 | $0.18811 | 12 / 11 | 5 / 6 |

Coding latency changed by **−4.8%**, estimated cost by **+3.7%**. Total standard-equivalent estimated token cost was **$0.42431** and active worker time was **73.67s**, within the four-run, $1.50 between-run cost threshold and 360-active-second registration. This estimate is not an actual OAuth invoice. All attempts completed; no unknown-usage or aborted cells were omitted.

## What actually changed

Both arms used GPT-6 Astra/high, normal history, the same fixture and task suffix, no hosted search, and identical native read/edit/write/job/planning schemas. The treatment removed only ls/find/grep and translated four interface-dependent prompt passages. Native tools and production defaults are unchanged; the candidate exists only in eval infrastructure.

The control used two native find calls; treatment used one shell find command. Both used six native reads, two native edits, reproduced the expected failing test before editing, and ran documented tests plus additional cache checks after the final edit. The emitted shell commands were reviewed: they listed files or executed tests, not source mutations. Fewer tool calls did not reduce model rounds: treatment used six versus five. Both arms' failed reproduction commands were necessary work, not wasted calls.

Coding input/cached/output tokens were 24,448 / 13,440 / 1,158 for native and 26,929 / 14,720 / 1,026 for treatment. These, together with all raw commands, request bodies, responses, grades, and final workspaces, are preserved; call count alone is not the outcome.

## Evidence and validity

- Registration: `evals/theories/astra_discovery_tools_screen.json`, seed 910, one run per arm/task, negative control first and randomized adjacent-pair arm order.
- Campaign: `evals/results/20260909-discovery-tools-screen/manifest.json`, `state.json`, `analysis.json`, and four cell directories.
- Exact tested code and fixtures: `evals/results/20260909-discovery-tools-screen/frozen-source.tar.gz`.
- Actual outgoing requests were audited by the campaign runner against exact baseline tool schemas and the registered prompt transformation, not merely an option label.
- Before launch: real Lua transformation/blocking tests, corrupted-schema rejection, registration validation, a full-grader known-good repair and four negative cases, `make local`, and `make test` passed. The campaign additionally ran its complete offline preflight.
- The existing bug grader checks verification after the first edit; this screen's stronger requirement was checked separately against the raw trajectory: in both coding cells the successful final verification followed the last edit.

## Limits and next decision

This is one coding pair, so the 1.66-second difference may be ordinary variation. It establishes neither a reliable speedup nor code-maintenance savings. Preserved editing tools and the restricted native-mutation task contract make it a different intervention from shell-only file access; do not pool those cohorts or relabel the earlier rejection.

Keep this as an eval-only candidate for fresh-task replication covering larger search spaces and more ambiguous discovery. Do not remove native tools, change production defaults, or claim the shell-only architecture is validated. Any replication needs a new registration and budget; none was launched as part of this screen.
