# Sol native-tool batching

## Decision

For native GPT-5.6 Sol sessions, explicitly ask the model to batch calls whose
arguments are already known, skip plans for bounded edits, batch independent
tagged edits, and combine independent focused verification commands.

## Evidence

The `sol_native_batching` theory ran three `existing_codebase_edit` cases per
variant. Both variants passed 3/3 at score 100 with zero failed mutations.

| Metric | Native control | Batched treatment | Change |
| --- | ---: | ---: | ---: |
| Mean model calls | 7.00 | 4.33 | -38% |
| Mean prompt tokens | 26,761 | 16,044 | -40% |
| Mean elapsed time | 34.5s | 29.2s | -15% |
| Mean estimated API cost | $0.0840 | $0.0674 | -20% |

Treatment runs used four to five model calls, retained three tagged edits per
run, and needed one to two verification calls rather than two in every control.

## Boundary

This is dependency-aware batching, not unconditional batching. A new model
round remains necessary when call arguments depend on prior results. Broad
multi-workstream tasks may still use a plan. Programmatic Tool Calling is a
separate experiment because it requires new `program`, `caller`, and
`program_output` protocol support.
