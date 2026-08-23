# Programmatic Tool Calling boundary

## Decision

Do not add Programmatic Tool Calling to LCA's default Sol loop yet. Preserve it
as a testable option for a future read-heavy, predictably reducible scenario.

## Reason

The current expensive authentication trajectory alternates semantic judgment,
writes, test results, and corrective edits. OpenAI's mechanism guidance assigns
adaptive search and writes to direct tool calling. Programmatic Tool Calling is
intended for predictable data flow where JavaScript can filter, join, aggregate,
or otherwise reduce several tool results before returning them to the model.

Supporting it would also expand LCA's stateless continuation protocol: it must
replay `program` and `program_output` items, preserve each nested function call's
`caller`, and continue a program through potentially multiple pauses. Native
function calling already batches independent repository reads, so this
complexity has no demonstrated benefit on the current orientation or auth cases.

## Future falsifiable test

Create a read-heavy scenario with several predictable queries whose raw results
can be mechanically reduced. Compare native direct calls against a read-only PTC
variant. Expose only non-mutating functions programmatically; keep edit, write,
run, and planning direct. Adopt only if correctness remains perfect and model
round trips or returned context fall materially.
