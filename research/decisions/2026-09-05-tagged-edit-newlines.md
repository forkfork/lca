# Fix tagged edits adding trailing newlines

## Observation

The Astra prompt pilot's `cell-0016` in
`evals/results/20260905-astra-workflow-prompt-v2/` took 85.6 seconds, nine model
calls and ten tools to make a single-line pipeline change. Its initial edit
succeeded but an exact-byte check failed. Astra investigated line endings and
eventually restored the intended file through a shell command.

The native edit used line 30, tag TW3O, and literal replacement
`            Step("transform", timeout_seconds=90, retries=4),`.
There was no trailing newline in the replacement argument. The edit tool itself
introduced the extra newline.

## Cause and fix

`read.split_lines` retains the empty segment after the final newline. Both
single-tagged and multi-edit writers joined those lines, then appended another
newline. Every such edit could grow an unrelated blank line.

The shared serializer now joins the retained segments directly. It adds a final
newline only when an edit replaces the displayed empty EOF segment with text,
preserving that existing append-at-EOF convention. Normal LF edits preserve the
original trailing newline count. CRLF normalization is an existing, separate
behavior and is not claimed fixed here.

Two new regression tests failed before the change and passed afterward. Coverage
includes repeated single edits, atomic multi-edits, no final newline, one or
multiple final newlines, last-line replacement, deleting lines, deleting the
whole content, and editing the displayed EOF segment. All 14 narrow edit tests
pass. The full Lua suite and 89 Python tests passed at the first post-fix check.

An independent replay copied the original fixture to a temporary workspace,
replayed the exact captured native edit, and compared every output byte against
the originally intended one-line replacement. It now passes immediately,
without any repair command.

The captured event timestamps put the first failed byte check at 34.575 seconds
and the final successful verification at 79.705 seconds: a 45.13-second interval
containing investigation, a failed CRLF guess, repair and re-verification. This
describes the observed repair sequence, not a counterfactual measured speedup.

## Decision

Keep this correctness fix. It eliminates a demonstrated source of avoidable
repair work. Do not claim that all 85.6 seconds were caused by the bug or promise
an unmeasured end-to-end speed percentage. The subsequent reasoning-effort screen
uses the fixed writer in every arm and includes the same pipeline task as a
post-fix regression workload.
