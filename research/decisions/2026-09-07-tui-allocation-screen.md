# TUI allocation screens — 2026-09-07

## Frozen baseline and registration

Checkpoint: `6f2dfe99dcfb722ad6f03fb0da364b2907e3bf77` (the existing checkout,
including earlier work, not a claim that its entire test suite was run).
The replay-profiler and recorded-fixture suites passed before the checkpoint.

Evidence directory: `/home/tim/lca-evidence/tui-allocation-20260907`.
This holds the archived checkout, installed lcatui Lua source, prior measurements,
new frozen candidates, manifests, complete ANSI output, and per-frame reports.
The local lcatui source directory is not a Git repository. Experiments use the
frozen installed Lua modules, not a modified dependency or production runtime.

Signal: the previous recorded-replay screen found repeated cell table and style
key construction; net heap decreases occurred in ~42–43% of measured frames.
Those observations did not measure allocation volume or GC pause duration.
No original slow UI raw log has been conclusively matched; these are offline
mechanism screens, not diagnoses of a reproduced interactive stall.

Three separate hypotheses (each compared to unchanged control):

1. **cells:** mutate existing cells in `Buffer:set` rather than replace tables.
2. **styles:** reuse the preceding style identity/key within one styled-line call.
3. **buffers:** reuse two alternating banks of buffers; reset existing cells rather
   than allocate a new blank screen. Keep the renderer's previous frame intact.

No combinations in the initial screen. Each comparison changes only its named
factor. Scenarios: full recorded fixture at 80x24/drift and 160x48/mycelium.
For each hypothesis run control/treatment at the first scenario and
 treatment/control at the second. This is 12 fresh-process full timing runs,
plus separate allocation-diagnostic passes for the same cells. Fixed seed 907;
one 40ms replay step and draw per frame; normal GC for timing. No model calls.

Timing primary metric: summed frame wall time; secondary p50/p95/p99/max,
CPU time and frames over 40ms. Timing uses a minimal driver without phase wrappers
or debug hooks, and identical ANSI capture in both arms. Compare complete ANSI
streams independently outside Lua. Differential buffer checks cover style mutation,
Unicode, boundaries, wide-to-narrow replacement, color-disabled output and pool
resize/reset/previous-frame preservation. Test the comparator with corrupted output.

Allocation diagnostic: a separate pass with capture disabled. Before each block
of 25 frames, perform a full GC, then stop automatic collection. Measure Lua heap
growth across each step/draw and restart GC after the block. This measures gross
Lua heap growth with GC stopped, not C allocator traffic, and is not a realistic
latency run. Reports and sample arrays are updated outside measured heap intervals.
Do not subtract normal-GC and stopped-GC timings to claim pause duration.

Advance a candidate only if all output/activation checks pass and either frame
work or gross Lua heap growth improves >=10% in both scenarios, with no >5%
frame-work regression in either scenario. Otherwise drop or mark inconclusive.
A screen supports further validation only, never default adoption. Budget: the
12 timing + 12 allocation runs above, local only; failures remain preserved.

## Protocol failure and v2 registration

The first 80-column cells pair produced 422 differing ANSI bytes despite equal
output length. A fresh unchanged control also differed from the first control
(43 bytes). Source inspection found overlapping actor glyphs drawn through
`pairs(self.actors)` in lcatui; the explicit math RNG seed does not stabilize
unordered table traversal across Lua processes. A same-Lua-state control/cells
comparison passed complete ANSI equivalence. This is evidence of a cross-process
replay-control problem, not grounds to classify the cell candidate as incorrect.

Stop v1 after its first pair; retain all four initial reports and three diagnostic
timing runs. Do not use these values for candidate adoption or pooled estimates.

V2 evidence: `/home/tim/lca-evidence/tui-allocation-20260907-v2`.
Freeze unchanged baseline and candidate sources with a new manifest. Change only
the comparison driver: each timing pair shares one Lua state, resetting the math
RNG, candidate hooks, app/renderer, and collecting garbage before each arm. Each
allocation pair uses a different fresh state from the timing pair. Keep the same
scenarios, pair ordering, metrics, and advance rule. Each pair's output must still
be byte-identical; no normalization or ignored differences. Add explicit assertions
that lcatui resolves to the frozen source and the cell intervention is activated.
Budget: 12 new timing plus 12 allocation replays. This remains a small mechanism
screen; leave all candidate code outside the production runtime.

## V2 results

All six paired comparisons passed complete ANSI equality, with no normalization.
Each replay processed all 1,214 fixture events and drew 2,550 frames. Each pair
emitted 5,207,150 bytes at 80/drift or 12,497,639 bytes at 160/mycelium.
Timing and allocation passes agreed on frame counts and output byte counts.

| Candidate | Scenario | Frame work, control → candidate | Work reduction | Gross Lua heap growth, control → candidate | Heap reduction |
| --- | --- | --- | --- | --- | --- |
| In-place cells | 80/drift | 1980.73 → 1901.78 ms | 4.0% | 569.94 → 433.53 MiB | 23.9% |
| In-place cells | 160/mycelium | 3940.91 → 3714.91 ms | 5.7% | 1071.43 → 803.76 MiB | 25.0% |
| Adjacent style keys | 80/drift | 1991.65 → 1447.92 ms | 27.3% | 569.94 → 485.35 MiB | 14.8% |
| Adjacent style keys | 160/mycelium | 3920.39 → 2954.18 ms | 24.6% | 1071.43 → 928.76 MiB | 13.3% |
| Two buffer banks | 80/drift | 1978.80 → 1781.45 ms | 10.0% | 569.94 → 123.81 MiB | 78.3% |
| Two buffer banks | 160/mycelium | 3929.16 → 3524.97 ms | 10.3% | 1071.43 → 581.22 MiB | 45.8% |

Heap values are totals across the complete replay measured with automatic GC
stopped in bounded blocks, not peak/resident memory, native allocations, or
normal-GC pause duration. The profiling phase wrappers were absent. These figures
are not comparable to the previous sum-of-net-decreases statistic.

P99 frame times (control → treatment): cells 1.407 → 1.341 ms and
2.245 → 2.121 ms; styles 1.400 → 1.198 ms and 2.273 → 1.853 ms;
buffers 1.365 → 1.222 ms and 2.256 → 1.993 ms. No measured timing frame
exceeded 40ms. Worst control frame was 3.032ms. These are CPU-side replay costs,
not observed terminal FPS or end-to-end input latency.

## Decision

All three meet the registered **further-validation** rule, not default adoption.

- **Styles first for speed:** the strongest isolated frame-work reduction, with
  a small local cache whose lifetime prevents stale keys across calls.
- **Buffer reuse first for allocation pressure:** the largest measured reduction
  in gross heap growth. It avoids constructing the blank cell grid each frame,
  while still retaining the original allocating `Buffer:set` implementation.
- **Cell mutation is secondary:** removes ~24–25% of heap growth, but only ~4–6%
  of frame work. It is worthwhile, not the dominant timing bottleneck.

Next experiment should combine styles with buffer reuse, then test the marginal
benefit of cell mutation on that combination. Do not add the isolated percentage
savings: they overlap and interact. No combined result is claimed here.

Before dependency adoption, validate multiple simultaneous temporary buffers,
effect transitions, resize/restart paths, Unicode edge semantics, callers retaining
cell references, and real-terminal rendering/input latency. Two-bank reuse must
be owned by the rendering lifecycle; the sandbox override is not a general-purpose
replacement for arbitrary callers of `Buffer.new`. No production lcatui or TUI
source was changed by these experiments.

## Evidence and verification

The v2 directory contains `manifest.json`, `registration.md`, `candidates.lua`,
`measure.lua`, `pair.lua`, `run.py`, `results.json`, per-pair comparisons, complete
ANSI streams, and per-frame reports. Source hashes were checked unchanged after
all measurements. The v1 directory retains the invalid cross-process screen and
its diagnostic replays; the previous profiling evidence is archived there too.

Candidate semantic/activation tests, known-good/known-bad output-comparator checks,
all six complete replay comparisons, and report-integrity checks passed. The two
project replay tests passed before the checkpoint. No installed runtime changes
were made, and neither the full project suite nor a real-terminal test was run.
To reproduce, copy the frozen inputs and drivers to a fresh evidence directory;
the driver deliberately refuses to overwrite an existing manifest/results run.
