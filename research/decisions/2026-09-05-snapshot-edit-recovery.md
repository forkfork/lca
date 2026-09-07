# Snapshot-backed recovery of mixed coordinates and tags

The user requested continued optimization experiments. The latest Snake trace
contains a concrete mismatch: after inserting `import math` at line 5, the model
advanced the later edit's coordinates from 62–124 to 63–125 but retained tags
`JPJA` and `lNQO`, which hash the original line numbers. Existing relocation
assumes the supplied coordinates are the original coordinates, so it rejects.
The rejected generation took 34.452 seconds and the retry response 34.839 seconds;
the latter also used transport fallback. These timings are not promised savings.

## Candidate and offline contract

`evals/edit_snapshot_recovery.lua` wraps the ordinary edit tool in frozen eval
roots only. Production tool code, schemas, prompt, and scheduling are unchanged.
It keeps one immediately preceding successful single tagged-edit receipt per
session, at most 128 KiB each for before/after contents, in a weak-key table.
Recovery requires the current full file to equal the recorded post-edit file,
a unique pair of old endpoint tags within 200 lines, unchanged complete range
contents at the supplied current coordinates, and a unique occurrence of that
range. The normal tool then performs validation and linting with corrected tags.
External changes anywhere in the file prevent this additional recovery path.
Existing ordinary edits and legacy relocation keep their original semantics;
this does not repair their pre-existing concurrent-write race boundaries.

Nine offline tests cover baseline rejection, successful exact-byte recovery,
external interior/exterior changes, session isolation, duplicate ranges, own
interior mutation, size limits, and syntax rejection. The captured Snake source
and literal tool coordinates/tags are replayed separately. Since the log truncates
the generated replacement body, that replay substitutes an inert comment and
checks exact surrounding bytes; it is not a replay of the entire visual feature.

## Preregistered live screen

Theory: `astra_snapshot_edit_recovery_screen`. Executable selector:
`evals/snapshot_recovery_screen.py`, which freezes two engine roots and selects
them through the normal eval driver. The generic runner cannot select these arms.
Four serial runs: simple baseline/treatment, then a seed-926 randomized adjacent
pair on `import_shift_edit`. Astra/high, normal history, all tools, identical
task prompts and native schemas. Lua 5.5 binary and LuaRocks module paths pinned.
Maximum 360 active seconds, 150 per cell, and a $1.50 between-cell estimated-cost
threshold with possible one-cell overshoot. No retries or default promotion.

The new fixture asks for a normal top-level math import and a distant function
change. It does not instruct the model to make a tag mistake. Independent public
and hidden checks grade behavior, protected scope, unrelated AST, and completed
post-mutation tests. Known-good and independently corrupted artifacts exercise
these grader gates before live calls. Source hashes establish tool wiring;
structured `snapshot_recovery` results establish actual behavioral activation.
Every outgoing request audits model/effort and normalized prompt/schema parity.

Stop on task, protocol, request-audit failure, unknown usage, or budget exhaustion.
Advance only if all pass, treatment recovers at least once, uses fewer model
rounds, takes at least 10% less time, and output tokens increase at most 10%.
Zero recoveries means nonactivation and parking, even if treatment happens to be
faster. A positive screen could justify fresh validation, not default adoption.

Evidence: `evals/results/20260905-snapshot-edit-screen-v2/`. The initial plan was
superseded before any model calls because offline runtime preflight found that
unqualified `lua` resolves to 5.4 on this machine. V2 pins 5.5 and its module paths
identically in both arms; the unused plan remains preserved.

## Completed: park for live nonactivation

All four runs passed artifact, evidence, native protocol and request audits.
The engine content hashes remained frozen. Normalized instructions, schemas,
model, reasoning and service tier matched on every outgoing request. There were
no failed live attempts, retries, missing usage, or recovered snapshot edits.

| Task | Arm | Time | Model calls | Tools | Output tokens | Estimated cost |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Simple | Baseline | 4.168 s | 1 | 0 | 5 | $0.040932 |
| Simple | Snapshot | 3.443 s | 1 | 0 | 5 | $0.040902 |
| Import/body edit | Baseline | 22.051 s | 4 | 6 | 284 | $0.103990 |
| Import/body edit | Snapshot | 18.165 s | 4 | 6 | 288 | $0.135254 |

Both coding arms read three files together, grouped the body and import edits,
ran tests once, and answered. The scheduler applied the edits bottom-to-top.
The 17.6% elapsed reduction cannot establish the recovery mechanism: it never
activated, model calls did not fall, and estimated cost rose about 30.1%.
Total standard-equivalent estimated cost was $0.321078, with 48.092 seconds of
active runner time. Estimates exclude service-tier and hosted-tool charges.

Decision: retain the bounded eval prototype and offline regression coverage;
do not change production editing or repeat this insensitive live task. Any next
live study should explicitly register a reconstructed recovery-boundary task,
with identical captured tool history in both arms, to measure conditional
recovery cost. That would still not establish how often real users benefit.

`make check` passed the full Lua suite and 110 Python tests. After the remaining
eval-runner/replay work, the Lua 5.5 adversarial and literal-tag replay checks and
the complete 110-test Python preflight passed; `make local` completed again.

## Checkpoint follow-up: small local cost

After all live cells finished, profiled the actual production
`experiment.capture` and `experiment.cleanup` functions three times, using the
existing small Snake project and current LCA engine tree. No source exclusion or
alternative copy implementation was used. The engine's eval-results directory
was about 193 MB at measurement time.

| Repetition | Capture | Cleanup |
| --- | ---: | ---: |
| 1 | 388.3 ms | 175.8 ms |
| 2 | 390.6 ms | 185.9 ms |
| 3 | 392.3 ms | 172.1 ms |

The observed combined overhead is roughly 0.56–0.58 seconds. This is real but
small compared with the tens of seconds spent regenerating edits. Deprioritize
checkpoint redesign on this evidence. These are local successive measurements,
not cold-cache, large-project or cross-filesystem benchmarks. Raw timings are
preserved beside the screen's offline evidence as `checkpoint-profile.json`.
