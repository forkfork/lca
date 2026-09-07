# Style keys + in-place cells — registered screen, 2026-09-07

Question: does adding cell mutation to adjacent-style-key reuse justify its extra
code and compatibility risk? Compare unchanged baseline, styles only, and the
combination; no buffer pooling and no production changes.

Frozen runtime: the same LCA checkpoint `6f2dfe99dcfb722ad6f03fb0da364b2907e3bf77`
and installed lcatui snapshot used in the isolated screens. Current documentation
checkpoint: `704c634f5d3aa68c45fcae8f16f9e49ba8d8fc13`.
Prior signal: style-key reuse reduced frame work 25–27%; cell mutation separately
reduced heap growth 24–25% but frame work only 4–6%. Original perceived interactive
stall remains unproven; this experiment measures offline implementation cost.

Evidence: `/home/tim/lca-evidence/tui-combo-20260907`. Preserve the copied source,
registration, source hashes, candidate, drivers, complete ANSI streams, per-frame
reports and failures. Do not overwrite earlier experiments.

Protocol: full 1,214-event recorded fixture; 2,550 fixed 40ms steps/draws. Scenarios:
80x24/drift and 160x48/mycelium. Each timing triplet shares one Lua process to
avoid the previously demonstrated cross-process rendering nondeterminism. Reset
the RNG (907), candidate methods, replay/app/renderer and GC before each arm.
Order: control/styles/combo at 80; combo/styles/control at 160. Timing uses normal
GC, identical ANSI capture, no phase wrappers. Separate fresh processes measure
allocation pressure using the existing stopped-GC, 25-frame-block diagnostic;
heap growth is not resident memory or GC pause time. No live model calls.

Budget: six full timing replays and six allocation diagnostics, plus bounded
correctness checks. No repetitions/default adoption from this screen.

Primary comparison: combo versus styles alone. Report total frame wall work,
p95/p99/max, CPU time, >40ms frames, and gross Lua heap growth; also report all
three arms relative to fresh control. Only cell mutation changes between styles
and combo. Validate both methods are active, differential buffer semantics,
Unicode/boundaries, style mutation across calls, and full byte-for-byte ANSI
output equality for all three arms. Check comparator against corrupted output.
Check source hashes unchanged at the end. Stop on output/activation failures.

Decision rule: advance combo to further validation only if output checks pass,
there is no >5% frame-work regression in either scenario versus styles, and
it saves >=5% frame work in both scenarios OR >=10% gross heap growth in both.
Otherwise prefer style-only or mark the comparison inconclusive. Do not add
isolated savings or claim terminal responsiveness from an offline benchmark.

## Results

All six timing replays and six allocation diagnostics completed. Each processed
1,214 events and 2,550 frames. All three arms produced byte-identical complete ANSI
output within each scenario: 5,207,150 bytes at 80/drift and 12,497,639 bytes at
160/mycelium. No output normalization was used.

| Scenario | Arm | Total frame work | P99 frame | Gross Lua heap growth |
| --- | --- | --- | --- | --- |
| 80/drift | Control | 1952.03 ms | 1.381 ms | 569.94 MiB |
| 80/drift | Styles only | 1415.62 ms | 1.168 ms | 483.87 MiB |
| 80/drift | Styles + cells | 1312.42 ms | 1.088 ms | 352.58 MiB |
| 160/mycelium | Control | 4022.88 ms | 2.292 ms | 1071.43 MiB |
| 160/mycelium | Styles only | 3022.49 ms | 1.887 ms | 926.47 MiB |
| 160/mycelium | Styles + cells | 2808.05 ms | 1.749 ms | 656.85 MiB |

Against fresh control, the combination reduced frame work **32.8% / 30.2%** and
heap growth **38.1% / 38.7%**, respectively.

The relevant incremental comparison is against styles alone: adding cell mutation
reduced frame work **7.3% / 7.1%** and heap growth **27.1% / 29.1%**. Thus the
cell change still contributes after the serialization optimization; it is not
merely duplicating savings already delivered by style-key reuse.

Heap figures come from the separate stopped-GC diagnostic, not timing runs. They
are aggregate Lua heap growth during the replay, not peak memory or GC pause time.
Normal-GC frame timings include the same minimal ANSI-capture overhead for all arms.

## Decision and validation boundary

**Advance the combination to further validation.** Both incremental timing and
heap gates passed in both scenarios. This supports keeping the two-method combo
as the small-code candidate; buffer pooling was not needed for these results.
It does not establish default adoption, compatibility for every lcatui caller,
or that the user's original perceived stall has been fixed.

Candidate activation checks verified both methods were replaced while buffer
construction remained unchanged. Differential semantics checks included the combo,
Unicode/boundary operations, cell continuation/style contents, no-color output,
and style mutation between calls. Known-good/bad comparator checks, complete ANSI
comparisons, report counts/output-size checks, and end-of-run source hashes passed.
The exact candidate, drivers, registration, input hashes, stdout/stderr, raw ANSI,
per-frame reports, comparisons, and decision are preserved in the evidence directory.

No production or installed dependency source changed. No full project suite or
real-terminal interaction test was run for this sandbox measurement. Before
shipping, verify callers retaining cell references and interactive resize/restart/
effect-transition behavior; the screen is one run per arm/scenario, not a robust
estimate across machines or workloads.

## Local adoption — September 7, 2026

Following explicit user approval, applied the measured style-key reuse and
in-place cell updates to `/home/tim/git/lcatui/lua/lcatui/buffer.lua` and added
regressions in `/home/tim/git/lcatui/tests/test_buffer.lua`. No buffer pooling,
persistent style cache, new configuration, or TUI scheduling changes were added.
The local lcatui directory has no AGENTS.md and is not a Git checkout; a reproducible
source-and-test patch is preserved at `research/patches/lcatui-buffer-allocation.patch`.
Apply that patch from the matching lcatui source root when reproducing this change.

Cell references are now explicitly live across set/fill operations; clear still
creates a new grid. Inspected LCA consumers read transition cells from separate
buffers or mutate the current cursor cell immediately; inspected lcatui renderer
consumers read cells during comparisons/serialization. No retained-cell snapshot
consumer was identified in those runtime paths. This is not a compatibility claim
for uninspected third-party users of Buffer.rows.

Verification completed:

- Six buffer tests passed, including in-place identity/field updates, combining
  and wide characters, clipping, style mutation between serialization calls,
  color-disabled output, and preservation of the previous rendered frame.
- Full lcatui suite passed. `make local` reinstalled both dependencies successfully;
  the installed buffer source was byte-compared against the changed checkout.
- Focused TUI/profiler/recorded-fixture suites passed, followed by full LCA
  `make test`, including the Python eval suites.
- Installed code matched the saved pre-change implementation byte-for-byte over
  two complete 2,550-frame replays (80/drift and 160/mycelium).
- A third installed/baseline comparison exercised contours, mycelium and filament
  transitions, resize, Unicode draft input and restart; its ANSI output matched.
- The actual replay command passed a bounded PTY smoke: raw mode, rendered typed
  draft, resize signal, paused restart, retained draft, clean Ctrl-C exit, restored
  canonical/echo terminal flags, and restored cursor visibility.
- The preserved patch passed an apply check and reproduced both changed source
  and tests exactly against the saved original files.

Adoption evidence and the original source backups are preserved under
`/home/tim/lca-evidence/tui-combo-adoption-20260907`.
The PTY smoke exercises actual terminal IO and the event loop, not a display
emulator; perceptual latency and the original reported stall remain unmeasured.
The earlier screen's 30–33% frame-work and 38–39% heap-growth reductions are
experimental measurements, not a new production benchmark or guaranteed FPS gain.
