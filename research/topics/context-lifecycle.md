# Context lifecycle

Status: initial synthesis, 2026-08-22.

## The actual choice is not “compact or clear”

The durable session and the model's active context should be different objects.
Pi keeps the full append-only session tree while sending a structured summary plus
recent verbatim messages after compaction. Codex similarly treats compaction as
replacement model input while maintaining a persistent rollout/session. Anthropic's
managed-agent write-up is explicit that a session need not equal one context window
and warns that irreversible selection is risky when future information needs are
unknown. [pi-compaction] [codex-loop] [codex-compact]
[anthropic-managed-agents]

This suggests four layers:

1. **Durable history:** every user/assistant/tool event, never recursively destroyed.
2. **Stable task state:** goal, constraints, decisions, worktree facts, changed files,
   verification status, blockers, and next action in a machine-readable checkpoint.
3. **Recent verbatim window:** enough intact turns to preserve local reasoning and
   tool-call/result pairing.
4. **Reloadable evidence:** source files, logs, test output, and old transcript ranges
   that can be retrieved again rather than narrated forever.

## What strong systems currently do

- Pi compacts near a configurable reserve threshold, keeps roughly 20k recent tokens
  by default, avoids cutting at tool results, handles split turns explicitly, carries
  cumulative read/modified file lists, and permits replacement compaction strategies.
  [pi-compaction] [pi-x-compaction]
- Codex preserves exact prompt prefixes for caching, then uses local or server-side
  compaction when its threshold is exceeded. The server endpoint can return opaque
  compaction state, which is a model/platform advantage LCA cannot reproduce for
  every provider. [codex-loop] [codex-compact]
- Claude Code recommends `/clear` between unrelated tasks, compaction for continuity,
  scoped compaction instructions, and subagents for verbose investigation. Its recent
  docs also recommend fresh-context adversarial review. [anthropic-best-practices]
- Anthropic's April 2026 session guide makes the boundary more explicit: continue for
  coherent work, rewind failed branches instead of carrying their debris, compact when
  continuity matters, and clear into a distilled brief when a clean session is more
  valuable. [claude-session-management]
- Factory argues for structured working memory, proactive phase-boundary compression,
  fresh-context retrieval workers, and deferring full tool/skill schemas until the
  capability is selected. These are vendor claims, but they produce concrete LCA
  hypotheses. [factory-compression] [factory-deferred-context]

## Field reports worth testing

Recent HN and Reddit discussions repeatedly report that long contexts accumulate
stale facts and that recursive compaction can lose important details. A recurring
workflow is to write or review a handoff/plan, start a fresh task context, and reload
facts from disk. Other users report good multi-compaction results when one scoped task
is anchored by a maintained plan. These reports disagree, which is precisely why the
boundary should be evaluated instead of hard-coded from anecdotes.
[hn-continuous-context] [hn-compaction-pi] [reddit-task-boundaries]
[reddit-compaction-failures]

A trailing-90-day refresh found the same disagreement in sharper form. One August
thread argues that repeatedly compacting week-long sessions causes rereads, cache
misses, and stale assumptions, while another reports that an explicit handoff plus
continued compaction outperformed a cold fresh session. A July thread recommends a
small active-context artifact containing open threads and gating conditions. These
remain practitioner reports, but they support testing phase checkpoints and fresh
rebases as separate policies instead of assuming either always wins.
[reddit-long-session-compaction-cost-2026-08]
[reddit-fresh-session-handoff-worse-2026-08]
[reddit-active-context-anchor-2026-07]

The first implemented result addresses a narrower mechanism: LCA formerly checked
full compaction only after an entire agent turn, even though a turn may contain forty
model/tool loops. A deterministic small-window eval showed 0/5 completion with that
boundary and 5/5 with a reserve check before every model call. This does not resolve
rolling compaction versus fresh rebase; it prevents a turn from crossing the window
before either strategy can run.

## Proposed LCA policy

Use semantic boundaries before token boundaries:

- **Same task, active phase:** keep recent turns verbatim; deterministically slim old
  read results and large command output first.
- **Same task, completed phase:** checkpoint structured state, then compact the
  completed phase. Rebuild facts such as current file contents and test state from
  tools rather than trusting prose summaries.
- **New or materially different task:** start a fresh model context with project
  instructions plus the new goal. Do not inherit an unrelated rolling summary.
- **High-volume exploration:** use an isolated worker/context only when its output can
  be reduced to a bounded evidence report. Do not delegate simple edits.
- **After repeated compactions or detected drift:** rebase from the original user goal,
  current structured checkpoint, worktree diff, and verification evidence. Preserve a
  pointer to full history rather than feeding the recursively summarized summary again.

The important optimization metric is tokens and successful actions per completed task,
not smallest prompt per request. A too-small summary that forces rediscovery is not a
win.

## Open design questions

- Should LCA's checkpoint be model-written, machine-derived, or merged from both?
- Which state is always preserved verbatim: original goal, latest user correction,
  plan, failed tests, modified-file set, or all of these?
- What drift signals should force a fresh rebase: repeated reads, stale edits,
  contradictory plans, test regressions, or N compactions?
- Should context promotion be sticky for the task or decay after a phase finishes?
- Can provider-specific opaque compaction beat portable structured checkpoints enough
  to justify different policies per provider?

## Sources

Source IDs resolve through [../sources.json](../sources.json).
