# Agent harness research

This folder is a living, evidence-linked notebook for improving LCA. Its discovery
feed is practitioner discussion from Hacker News, Reddit, and X published during the
trailing 90 days. Current source code and LCA evals are then used to test the ideas
surfaced by that feed.

## How to use it

- Start with [topics/edit-tools.md](topics/edit-tools.md) and
  [topics/context-lifecycle.md](topics/context-lifecycle.md), then
  [topics/instructions-and-capabilities.md](topics/instructions-and-capabilities.md).
- Use [experiments.md](experiments.md) as the bridge from research to evals.
- Check [sources.json](sources.json) for publication dates, retrieval dates, pinned
  commits, and source role.
- Add each new search pass to `field-notes/YYYY-MM-DD.md`; do not silently rewrite
  old observations as the ecosystem changes.
- Follow [refresh.md](refresh.md) when updating the research.

## Source roles

Discovery priority and validation strength are deliberately separate:

- **Discovery feed:** HN, Reddit, and X posts published in the trailing 90 days. This
  is the primary source of new techniques, sharp failure reports, and disagreements.
- **Mechanism check:** current pinned source code, traces, issues, and maintainer
  explanations used to determine whether a reported mechanism is real.
- **Validation:** repeatable LCA evals. This decides whether an idea becomes an LCA
  behavior.
- **Baseline/archive:** vendor documentation, older engineering posts, and papers.
  These provide vocabulary and history, but are not evidence that a technique is
  current or effective.

`retrieved_at` never establishes freshness. Community sources must have
`published_at` (or an explicit observed age) and must be inside the 90-day window at
the time of the scan. Older sources remain only when a note needs historical context.

## Current thesis

The strongest harnesses do not win through one magic prompt. They combine a small
agent loop with model-compatible edit representations, aggressive feedback from
tools and tests, durable state outside the context window, and explicit policies
for what remains verbatim, what is summarized, and what is reloaded on demand.
