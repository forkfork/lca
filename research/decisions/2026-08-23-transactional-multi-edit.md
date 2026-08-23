# Transactional multi-edit experiment

Date: 2026-08-23

## Decision

Keep the transactional `multi_edit` implementation and eval intervention, but do not
advertise it in the production tool catalog by default. Adopt only the independent
bounded tag-relocation behavior for ordinary tagged edits.

## Mechanism tested

`multi_edit` accepts one path and up to twenty non-overlapping tagged hunks. It reads
one snapshot, validates every endpoint before applying anything, rejects overlaps,
applies hunks bottom-to-top in memory, runs one syntax check, and performs one write.
Any stale, invalid, overlapping, or syntax-breaking hunk rejects the whole call.

The control hides both the schema and prompt guidance through the eval driver's
`multi_edit_enabled` intervention. The treatment exposes them. Mutation payload bytes
and multi-edit hunk counts were added to the eval metrics.

## Evidence

After a one-run raw-trajectory pilot, the randomized comparison used three runs per
cell on `existing_codebase_edit`, `repeated_text_edit`, `stale_edit_recovery`, and the
new `multi_location_edit` discriminator. `multifile_order_cancellation` was extended
symmetrically to five runs per cell because its first three runs landed within one
third of a mutation call of the predeclared ten-percent boundary.

All corrected trajectories passed their deterministic behavior, scope, and
verification gates. Twelve initial narrow failures were grader false negatives:
Python 3.14 rewrote ignored `__pycache__` files that two graders mistakenly included
in scope comparison. Raw trajectories showed correct focused edits and green tests;
the graders now exclude generated cache directories on both fixture and workspace
sides, and all twelve saved workspaces regraded successfully.

| Scenario | Cell | Pass | Tools | Model calls | Mutations | Failed mutations | Latency |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| multi-location | single range | 3/3 | 7.0 | 4.67 | 3.0 | 0 | 15.75s |
| multi-location | transactional | 3/3 | 5.0 | 4.0 | 1.0 | 0 | 14.16s |
| realistic multi-file | single range | 5/5 | 13.6 | 8.0 | 3.0 | 0 | 56.64s |
| realistic multi-file | transactional | 5/5 | 14.2 | 8.8 | 3.4 | 0.2 | 55.59s |
| existing codebase | single range | 3/3 | 10.0 | 4.0 | 3.0 | 0 | 27.00s |
| existing codebase | transactional | 3/3 | 10.67 | 5.33 | 3.0 | 0 | 31.94s |

The repeated-text negative control was slightly faster under treatment and the forced
stale-recovery cells were effectively equivalent. Neither uses multiple independent
hunks, which is the intended boundary.

## Why the production default stays unchanged

The discriminator proves that the atomic interface is useful when three distant
same-file replacements are definitely present. The realistic scenario shows the
model does not select it reliably enough to justify paying catalog/prompt overhead on
every task. Treatment missed the predeclared broad threshold: mutations rose 13.3%,
model calls rose 10%, and one run split line-shifting same-file edits across rounds,
causing a stale-tag recovery. Correctness was preserved, but the optimization is not
yet a general default.

## Adopted line-shift recovery

The failed broad trajectory exposed a safe narrower mechanism. A prior tagged edit
inserted one line above a later unchanged range; the later CAS tags still identified
the original endpoint contents but at a common +1 offset. Ordinary tagged edits now
search at most 200 lines around a mismatch and relocate only when both endpoints have
exactly one candidate and share the same nonzero offset. Changed content, inconsistent
offsets, and duplicate candidates still return `stale tag`. Focused tests replay the
successful relocation and ambiguous rejection.

## Remaining work

A future promotion policy could expose `multi_edit` only after the harness knows that
multiple independent same-file replacements exist. That needs a separate experiment;
do not broaden the default catalog from the current evidence.
