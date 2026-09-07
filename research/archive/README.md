# Retired implementation snapshots

`2026-09-05-retired-experiments.tar.gz` preserves the working-tree implementations
and associated tests immediately before retiring read-only delegation, tool
dependency DAGs, and automatic read-only fork/join. It also contains the obsolete
XML exact-edit prompt transform and unused protocol helpers.

These experiments did not pass their promotion gates. Removing them from the
runtime is a maintenance decision, not proof that delegation or scheduling can
never help. Their original theory manifests, decision reports, raw trajectories,
and metric readers remain intact. No historical evidence was rewritten.

Historical experiment switches now fail explicitly in the eval runner before
any model call; they do not silently run the baseline. Old saved sessions ignore
retired fields and rebuild their cached system prompt. Normal tool batching,
read budgets, mutation ordering, tagged edits, and compaction remain active.

For recovery, extract the archive into a **separate scratch directory**, never
over the live checkout. The snapshot includes unrelated in-progress changes;
review and selectively port any desired implementation. It is not a complete,
reproducible engine checkout and is not supported by the current test runner.

## Planning and cache probes

`2026-09-05-planning-cache-probes.tar.gz` preserves the temporary planning profile,
its prompt-transform support, and the read-only cache capability probes and tests
before cleanup. It also includes the relevant pre-promotion driver, runner, and
registry snapshots. Restore selectively into a separate scratch directory.

The user explicitly chose to keep the planning clarification after the positive
six-run screen. It now lives beside the existing planning guidance in the normal
native-tool prompt. This is a user-directed adoption, not a claim that one screen
established general superiority. The old `planning-clarity` profile fails before
workspace creation/model calls rather than appending duplicate guidance or
silently turning the old experiment into two identical arms.

The cache-options probe failed endpoint compatibility (`prompt_cache_options`
was rejected), so its task-specific live sender and answer checker are archived.
The historical `wire_probe` variants also fail before any workspace/model work.
Original theory manifests and saved results remain intact. The reusable cache
prefix analyzer, exact serialized-request capture, and their tests remain active.

## Snapshot edit recovery

`2026-09-05-snapshot-recovery.tar.gz` preserves the rejected eval-only snapshot
recovery implementation, dedicated runners, fixtures, graders, tests and theory
registrations. Its companion manifest records SHA-256 hashes verified against
the archive before removing these files from the active checkout. No production
feature flag existed. Decision reports and original `evals/results/*snapshot*`
evidence remain intact; restore only into a separate scratch directory.

## Workflow prompt deletion

`2026-09-06-workflow-prompt.tar.gz` preserves the nine-line deletion spec, Lua
transform, former Python audit/tests and pre-removal harness files. The companion
manifest verifies their hashes. The fresh-task replication failed its speed
gates, so the deletion code and executable `workflow-lite` profile were removed.
Historical theory registrations and raw results remain intact; historical
profile requests now fail before workspace creation or model calls. The current
prompt is unchanged. Restore only into a separate scratch directory.

## Legacy edit and prompt probes

`2026-09-06-legacy-edit-and-prompt-probes.tar.gz` preserves the old edit executor,
its integration fixtures, and eval harness before removing the unadvertised
oldText/newText mutation path, rejected repository-facts probe, and obsolete
lean/minimal prompt transforms. The companion manifest records verified hashes.
Normal tagged edits and multi-hunk editing remain supported. Historical eval
registrations and results remain intact; retired profiles fail before work begins.
Restore selectively into a separate scratch directory.
