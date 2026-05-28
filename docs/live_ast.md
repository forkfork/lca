# Live AST Turn State

LCA's long-term UI direction is to render each agent turn as a live recursive value being evaluated, not as a flat transcript of tool calls.

The working metaphor is:

```lua
turn {
  intent = ok("create Lua auth API")
  context = ok("existing crap1 pattern found")
  tool_batch = streaming("12 tools, 9 closed")
  changes = pending()
  verify = pending()
  return_value = pending()
}
```

As model output streams and tools execute, events patch this object. Completed subtrees collapse, active subtrees stay expanded, and failures remain local to the node that failed.

## Value

- Long hidden tool streams show semantic progress instead of dead air.
- Cancellation can preserve partial evaluation state, such as complete-but-unexecuted tool calls.
- Final answers can be grounded in actual evidence nodes.
- Session history can compress completed subtrees instead of preserving noisy logs.
- Future commands can query the tree: unresolved nodes, failures, evidence, or resumable work.

## Node Model

Each node has:

- `kind`: stable semantic category such as `intent`, `inspect`, `changes`, `verify`, `serve`, `tool_batch`, or `return_value`.
- `status`: `pending`, `streaming`, `running`, `ok`, `warning`, `error`, `cancelled`, or `unknown`.
- `detail`: short human-readable value.
- `evidence`: tool-derived facts backing the detail.
- `children`: recursive subnodes.
- `meta`: structured counters and task-specific state.

The renderer should treat unknown node kinds generically so domain-specific work can grow new subtrees without UI rewrites.

## Event Sources

Initial implementation consumes:

- User intent: creates `intent`.
- Tool stream opens/closes: updates `tool_batch`.
- Tool start/result events: update semantic frames such as `inspect`, `changes`, `verify`, and `serve`.
- Cancellation: marks incomplete work as `cancelled`.
- Return value: records the turn's final deliverable.

Later stages should feed plan updates, provider salvage metadata, compaction checkpoints, browser verification, and dirty worktree risk into the same state object.

## Migration Path

1. Keep existing transcript rendering intact.
2. Build `agent.turn_state` as an independent semantic model with tests.
3. Feed live stream/tool events into a turn state instance inside the REPL.
4. Render the AST in a small live summary block.
5. Move cancellation and partial-salvage reporting onto the AST. Cancelled provider calls that already produced a salvaged tool prefix should preserve the recovered tool count so the UI can say the calls are complete but unexecuted.
6. Use the AST summary as the basis for final-answer grounding and context compaction.

## Session And Compaction

When the experimental renderer is enabled, the REPL records the latest turn's compact AST summary and serializable snapshot on the session as `last_turn_ast_summary` and `last_turn_ast_snapshot`. Save/load preserves both fields.

Compaction receives the compact summary in a `<recent-turn-ast>` block. The summarizer should treat this as grounding evidence for what actually happened, especially changed files, verification, failures, cancellation, and partial tool-batch salvage.
