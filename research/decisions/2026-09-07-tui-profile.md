# TUI replay performance investigation — 2026-09-07

## Registered offline screen

Observed signal: user reports TUI slowdowns and supplied the recorded workload
`tests/fixtures/tui-performance-analysis.jsonl`. The matching original raw run log
has not been identified; do not infer provider or tool latency from this replay.

Mechanisms to distinguish: event/state preparation, duplicate zero-time refresh,
scene composition/effects, ANSI serialization, and output transport. No model calls.

First measure the unchanged full fixture at 80x24 and 160x48 with drift, fixed
40ms steps, one replay draw per step. Preserve per-frame traces outside the checkout
under `/tmp/lca-tui-profile-20260907`, with fixture/source hashes and runtime module
locations. Instruction sampling is a separate diagnostic run, not a timing baseline.

After phase attribution, register one concrete intervention before comparing it.
Use adjacent control/treatment pairs with the same fixture, dimensions, cadence,
effect, and source hashes. Primary metric: total measured frame work; also report
p95/p99 and >40ms frames. A screen can justify further validation, not a default
change. Require independently compared rendered ANSI output or styled cells; retain
failed comparisons. No timing thresholds in correctness tests.

Budget: at most six initial full timing runs and two sampled runs; local only.
No production optimization is accepted without separate correctness verification.

Limitations: discard-backend results exclude terminal backpressure, emulator paint,
input scheduling, live provider callbacks and tools. Fixed-step throughput does not
measure observed FPS. Heap deltas are not allocation volume or GC pause attribution.

## Registered intervention after baseline attribution

Baseline serialization consumes 43% (80 columns) / 50% (160 columns) of frame
work. Instruction samples and source show repeated style-key construction for
adjacent cells sharing the very same style table.

Screen candidate: cache only the immediately preceding style identity/key inside
one `Buffer:styled_line` call. Never cache across calls (styles are mutable).
Freeze the candidate outside the checkout; do not change the dependency default.
Run four full replay measurements: control/candidate at 80x24, candidate/control
at 160x48. Capture and compare the complete ANSI stream in each pair. Validate
nil/string/table styles, wide/combining text, color-disabled output and mutation
between calls independently. Advance if both pairs are output-identical and total
frame time improves >=10%; otherwise drop. This screen cannot establish that the
user's perceived slowdown is serialization, nor justify changing the default.

## Results and decision

Each full replay covered 102 seconds, 1,214 events, and 2,550 drawn frames.
The time-zero event is applied during setup and reported separately; setup/load
and report serialization are excluded from measured frame work.

Unchanged baselines:

| Terminal dimensions | p50 / p95 / p99 frame work (ms) | Worst (ms) | Frames >40ms | Output |
| --- | --- | --- | --- | --- |
| 80x24 | 0.74 / 0.98 / 1.29 | 2.04 | 0 | 5.21 MB |
| 160x48 | 1.29 / 1.57 / 1.94 | 2.39 | 0 | 7.93 MB |

Serialization took 43–50% of measured frame work; scene composition took 32–34%.
Effect rendering was only 3–4%; duplicate zero-time preparation was 1.5–2.5%.
The measured workload does **not** reproduce a CPU frame-budget problem.
The largest baseline frames were not consistently event bursts.

Controlled candidate screen (capture enabled identically in both arms):

| Dimensions | Control total frame work | Candidate | Reduction | Control → candidate p99 |
| --- | --- | --- | --- | --- |
| 80x24 | 1956.32 ms | 1360.19 ms | 30.5% | 1.34 → 1.08 ms |
| 160x48 | 3353.11 ms | 2244.10 ms | 33.1% | 1.95 → 1.44 ms |

Both complete ANSI streams were byte-identical (5,207,150 / 7,929,122 bytes).
Independent mixed-style, Unicode, no-color and between-call mutation checks passed.
Instruction sampling identified style-key construction and buffer allocation/width
work; its timings were deliberately not mixed with baseline timings.

**Decision: further validation, not adoption.** The local adjacent-style-key cache
is the first CPU optimization to pursue in lcatui. It passed the registered screen,
but needs dependency-level regression coverage and fresh workloads/effects before
promotion. Neither the dependency nor production TUI behavior was changed.
Do not prioritize removing animation or the extra replay refresh on this evidence.

The renderer currently rewrites the whole inline strip whenever the buffer changes.
That is a plausible terminal-side concern, not a measured explanation of the user's
slowdown. Next diagnostic should measure timer lateness and actual write/flush wall
time in the user's terminal, correlated with the slow fixture interval and input
response. A drained PTY cannot establish emulator paint latency. Neither real-terminal
nor PTY latency was tested here; the new runner measures offline cost only.

## Reusing the profiler

`lua scripts/tui-profile.lua FIXTURE REPORT [WIDTH HEIGHT EFFECT [UNTIL_SECONDS [sample]]]`

Use the recorded fixture, a writable JSON report destination, and e.g. 160 48 drift.
The report contains exclusive (non-double-counted) phase totals, every frame's
wall/CPU time, event range, state sizes, output bytes/calls, heap observations,
and the ten worst frames. `sample` enables optional Lua instruction samples;
it is not a native or wall-time sampling profiler. Keep sampled runs separate.
No per-frame logging or forced GC is used by the normal benchmark. Reports are
written after playback. The runner restores shared wrappers even after a failure.

Raw traces, complete ANSI streams, frozen candidate and hashes are preserved at
`/tmp/lca-tui-profile-20260907`; this is temporary storage, so archive it before cleanup.
The initial source-hash command failed because the shell did not expand braces;
it was corrected before running the candidate. No timing run failed.

Verification: `make local` passed; `tests/test_tui_profile.lua` and
`tests/test_tui_recorded_fixture.lua` passed. The profiler test independently checks
complete ANSI equivalence, exclusive timing accounting, percentiles, instruction
sampling, invalid dimensions and cleanup after injected rendering failure.
No shared production code changed, so the full suite was not run.
