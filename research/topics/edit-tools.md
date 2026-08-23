# Edit tools

Status: initial synthesis, 2026-08-22.

## What the evidence says

There is no context-free “best” edit format. Reliability depends on the model,
file size, change shape, and whether the model was trained on a particular patch
language. Aider explicitly selects formats per model and its benchmark records
format compliance separately from task correctness. Diff-XYZ likewise finds that
different representations win at generation, application, and analysis rather than
one format dominating every operation. [aider-edit-formats] [aider-benchmarks]
[diff-xyz]

Three mature patterns are worth distinguishing:

1. **Exact search/replace.** Pi asks for one or more small, unique `oldText` blocks
   and replacement text. All replacements are resolved against the same original
   file, overlapping edits are rejected, and the implementation reports actionable
   ambiguity/mismatch errors. It normalizes line endings and a narrow class of
   whitespace/Unicode differences, while preserving unchanged original lines, BOM,
   and line-ending style. Same-file mutations are serialized. [pi-edit]
   [pi-edit-diff]
2. **Patch language.** Codex exposes a file-oriented `apply_patch` envelope with
   add, update, delete, and move operations. This is expressive and reviewable, and
   is especially compelling when the model is trained to emit that exact grammar.
   It adds parser and patch-application failure modes that plain replacement avoids.
   [codex-patch]
3. **Whole-file output.** This is the easiest fallback for weak format followers and
   small/new files, but it consumes output tokens, increases accidental churn, and
   becomes impractical on large files. Aider keeps it as a model/task-dependent
   option rather than its universal default. [aider-edit-formats]

Aider's architect/editor mode is a separate axis: one inference solves the change,
then a narrowly prompted editor inference translates the solution into edits. Its
published benchmark showed large gains for the model combinations tested, but this
is older, model-specific evidence and doubles important parts of latency/cost.
[aider-architect]

## LCA today

LCA's tagged range edit is a useful compare-and-swap design: line tags detect stale
reads, multiple non-overlapping ranges can be applied bottom-up, and syntax checks
can block newly introduced parse errors. Its legacy exact `oldText` path rejects
zero or ambiguous matches. The main weakness is that the preferred line-range form
encourages the model to reason about line coordinates and requires raw replacement
content, while the exact-text form cannot express multiple replacements in one call.

## Recommended blend

Do not replace LCA's edit tool with generic unified diff. Test a blended interface:

- Keep `write` for new files and genuinely small whole-file rewrites.
- Make multi-edit exact replacement the default for existing files:
  `path + edits[{oldText,newText}]`, with every match resolved atomically against the
  same original snapshot.
- Retain tagged ranges as a fallback for deletions, repeated text, and edits already
  grounded in a recent tagged read.
- Normalize CRLF/LF and BOM for matching but preserve the original representation.
- Return a compact unified diff as output regardless of the input representation.
- On failure, return the closest local context and a typed reason (`not_found`,
  `ambiguous`, `overlap`, `stale`, `syntax_error`) so the next model turn can repair
  only the failed edit.
- Select the preferred representation per provider/model only after measuring it;
  native `apply_patch` may be best for Codex-family models without being best for
  every provider LCA supports.

## Failure modes to measure

- Correct intent, invalid edit grammar.
- Exact block fails because whitespace or line endings drifted.
- Ambiguous block edits the wrong occurrence.
- Two same-file edits observe different snapshots.
- Whole-file rewrite silently drops unrelated code.
- Patch applies cleanly but to the semantically wrong location.
- Error feedback causes the model to resend already-applied edits.

## Sources

Source IDs resolve through [../sources.json](../sources.json).
