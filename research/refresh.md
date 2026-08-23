# Refresh procedure

Use this process for periodic research updates.

1. Record a new `field-notes/YYYY-MM-DD.md`; never overwrite the prior scan.
2. Set the inclusive cutoff to exactly 90 days before the scan date.
3. Search HN, Reddit, and X first. Record original posts and useful dissenting replies,
   not search-result summaries. Require a publication date or observed age that proves
   the item is inside the window.
4. Cluster repeated pain and hacks before looking at vendor explanations. Prefer
   reports containing traces, reproduction steps, measurements, patches, or links to
   source.
5. For each promising mechanism, inspect the current implementation, issues, and
   diffs in Pi, Codex, Claude-adjacent open tooling, Aider, OpenHands, SWE-agent, and
   newly relevant harnesses. Pin the exact commit inspected.
6. Consult vendor docs only to establish baseline behavior or clarify a public API.
   Mark them `baseline`; do not use them to rank innovative ideas.
7. Update `sources.json` with `published_at`, `retrieved_at`, `role`, and pinned commit
   where applicable. Keep older sources only when a note needs historical context.
8. Update topic notes only when evidence changes a claim. Preserve disagreement.
9. Convert the strongest ideas into experiments in `experiments.md`. LCA eval results,
   not social consensus or vendor claims, decide adoption.

Suggested research prompt:

> Refresh `research/` with HN, Reddit, and X posts published in the trailing 90 days as
> the primary discovery feed. Mine concrete workflows, failures, hacks, disagreements,
> traces, and measurements. Then inspect current source code and issues to validate the
> claimed mechanisms, and turn the strongest ideas into falsifiable LCA evals. Record
> `published_at`, `retrieved_at`, source role, mechanism, tradeoff, and proposed eval.
> Treat vendor docs as baseline/archive material, never as proof of innovation.

Questions to rotate through:

- Which edit representation works best for each current model family?
- How do agents recover from failed or stale edits?
- What remains verbatim across compaction, and what is reconstructed?
- When do fresh contexts beat continuing/compacting contexts?
- How are large tool catalogs and MCP schemas deferred?
- When do subagents improve total task performance rather than merely parallelism?
- Which verification feedback is returned immediately versus at turn boundaries?
- How do leading harnesses measure tokens per task, cache hits, retries, and drift?
