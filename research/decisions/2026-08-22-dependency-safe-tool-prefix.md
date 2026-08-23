# Decision: preserve the dependency-safe prefix of a tool batch

Date: 2026-08-22

Decision: accepted as a core-loop invariant.

## Evidence

An `existing_codebase_edit` trajectory emitted three valid file edits followed by a
read of one of those files in the same assistant response. Because model generation
cannot observe mutation results from earlier calls in that response, the read belongs
to a later dependency phase. The previous executor considered the whole response a
read/write conflict and rejected the earlier edit. Its recovery applied an incomplete
replacement and the hidden behavioral test failed.

LCA now executes the coherent prefix ending before the first read-after-mutation,
stores only that executed prefix in assistant history, and tells the next model turn
to continue from the mutation results. A deterministic core-loop test reproduces the
exact response shape and proves the earlier mutation persists while the read is
deferred. The full Lua suite passes.

## Limits of the claim

This fixes batch scheduling, not semantic coding quality. A five-run tagged-edit
confirmation had zero failed mutations but only 3/5 behavioral passes because two
runs omitted validation required for directly constructed model objects. Those
failures must not be credited to or blamed on dependency-prefix scheduling.

The transcript metric `dependency_prefixes` records future occurrences so this policy
can be evaluated on natural traffic rather than assumed beneficial from one incident.
