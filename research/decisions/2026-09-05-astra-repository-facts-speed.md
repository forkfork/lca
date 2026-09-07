# Observed repository facts speed screen

Registered before launch: `astra_repository_facts_speed`, seed 915, 20 runs,
$5 between-run estimated-cost threshold, 1400 active worker seconds. Compare
current prompt against current prompt plus the observed startup Git work-tree
fact; keep Astra/high, all tools, scope and history fixed. Four separate smoke
runs precede sixteen pilot runs. See the theory for exact task contracts.

Primary gates: no per-task pass-count loss, at least 10% lower aggregate coding
latency, lower medians on two of three tasks, cost increase no greater than 10%,
and strictly fewer failed commands reporting a non-Git workspace. No such errors
in the control means the proposed mechanism is untested rather than approved.
Require fresh validation including an actual Git task before default changes.

Offline probes cover actual Git roots and nested paths, non-Git directories,
missing Git, failed probes and shell-sensitive paths. Unknown results are not
misrepresented as non-Git. Independent preserved-workspace auditing prevents
the artifacts from inheriting the parent LCA checkout's Git metadata.

The preceding local-tools experiment reduced coding time 11.91% and estimated
cost 29.03%, but missed its 15% speed gate and was not promoted. This new study
does not combine the two interventions. No normal production prompt changes.

## Completed: mechanism observed, speed gate not met

All 20 runs passed. Total standard-equivalent estimated cost was $3.492268;
active worker time 703.336 seconds. Source and manifest hashes matched at
completion; every prompt/tool/usage audit passed. Coding runs had completed
verification after their edits. Six primary coding runs per arm, each task 2/2.

| Task | Current median | Repository-facts median |
| --- | ---: | ---: |
| Ambiguous investigation | 53.548 s | 43.850 s |
| Existing multi-file code | 32.989 s | 34.654 s |
| Multi-file cancellation | 64.140 s | 65.973 s |

| Arm | Coding time | Coding cost | Model calls | Tools | Non-Git failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| current | 301.353 s | $1.443522 | 33 | 71 | 1 |
| repo-facts | 288.952 s | $1.368268 | 29 | 68 | 0 |

Time improved 4.12%, estimated cost 5.21%. The treatment avoided the measured
Git failure but missed the 10% aggregate speed gate and improved only one of
three task medians. Do not promote the prompt change or automatically expand
this study. A correct environment fact may still be useful, but this cohort
does not establish the registered speed benefit. One failure with small samples
also limits the mechanism estimate.

Control cell-0009's failed Git-first verification command completed at 42.213 s;
the regenerated successful command completed at 56.767 s. Preserve the observed
repair interval without treating it as a controlled counterfactual saving.

During collection the user requested a faster experimentation loop. The queued
long-build calibration was deferred before any model call, and a separate
4–6-run screen tier replaces repeated large matrices for initial exploration.
The already-near-complete Git campaign retained its original decision rules.
