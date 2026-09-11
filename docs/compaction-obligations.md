# Operational evidence across compaction

LCA keeps an `operational_state` record in the saved session independently of the
generated summary. The summarizer receives the current record. Compaction embeds
a snapshot in the retained checkpoint message; resume adds a snapshot once.
Those snapshots stay unchanged in conversation history. Later tool calls use their
ordinary results, and the next compaction captures the updated record.

This avoids replacing a temporary state message on every model request. Such a
replacement discarded the previous implicit cache endpoint even though the earlier
text remained identical. Pending resume snapshots count toward context estimates;
after insertion, ordinary history accounting counts them once. Compaction still
replaces old history and can require a new cache entry.

The snapshot is historical evidence at its boundary, not continuously refreshed
job status. Later tool results and explicit job inspection establish newer facts.

The record retains:

- The latest 24 command outcomes and 24 file-tool outcomes, with bounded output,
  arguments excluding edit payloads, call IDs, and event sequence numbers.
  Successful verification and subsequent edit operations remain distinct events.
- Older failed outcomes until a successful call with identical tool arguments
  replaces their separate retention entry. This is a retention rule, not a
  determination that a failure remains unresolved. Recent outcomes are deduplicated
  against these entries when rendered.
- Calls for which no completion was observed, including across session restore.
- Known jobs and running jobs discovered in the workspace, with their last observed
  status and output references. Completion does not establish that output was
  inspected or that the task is verified.
- Unfinished plan items, explicitly identified as agent declarations.

The harness no longer assigns source revisions or marks command outcomes stale
because another shell command ran. `evidence` and `completed_at` record event
order, including overlapping calls; neither is a filesystem version. A session
restore is reported as an observation boundary, not an invalidation of every pass.
Previously saved revision/overlap classifications are omitted from model context.

The agent and summarizer must judge which evidence applies to the remaining task.
Read-only inspection does not invalidate successful verification; subsequent
relevant edits can. Arbitrary shell commands and external processes can change
files, and receipts alone do not detect those changes. A passed command is not
necessarily a test. Historical failures are not instructions to retry.

Command output and failure diagnostics are bounded to 1,200 bytes. Call IDs link
to full run logs. Tracking starts when enabled, and older events can be absent;
this is not a complete history or a validated semantic obligation registry.
Constraints, prose-only pending checks, user non-goals and rejected alternatives
still depend on the summary unless represented in execution history or the plan.

The simplification follows the
[discrimination screen](../research/decisions/2026-09-11-obligation-discrimination-screen.md):
a read-only command caused an earlier pass to be classified stale, and the
summarizer converted that classification into an unnecessary rerun instruction.
The captured Ready history is now a regression fixture. Tests check that the failed
attempt, successful retry with a changed timeout, and read-only inspection reach
both consumers without inferred freshness or unresolved-work labels. Other tests
cover actual edit events, overlap ordering, history rollover, save/restore,
incomplete calls, jobs, and core request integration. These tests establish
mechanical behavior; live improvement from this revision remains unmeasured.
