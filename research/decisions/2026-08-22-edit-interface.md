# Decision: keep tagged range edits as the default

Date: 2026-08-22

Decision: retain LCA's tagged range edit tool. Keep exact `oldText`/`newText`
replacement available only as an eval profile and possible future fallback.

## Evidence

The first existing-codebase comparison did not isolate edit mechanics. Exact
replacement passed 5/5, while tagged ranges passed 4/5 and then 3/5 in a confirmation,
but every tagged failure was the same semantic omission: the implementation skipped
validation when callers directly constructed the dataclass. The edit itself applied
cleanly. Exact also required more model calls on average.

Two focused scenarios then isolated the relevant mechanics:

- `repeated_text_edit` requires one precise change among similar configuration blocks.
- `stale_edit_recovery` mutates the target line after the agent reads it and requires
  both the requested change and the injected annotation to survive.

Both interfaces substantively passed 5/5 on both scenarios. A generated
`.pytest_cache` directory initially caused one exact run to fail scope grading even
though its code and behavior were correct; the grader now excludes interpreter and
test-runner caches, and a replacement run passed.

| Scenario | Tagged | Exact | Main efficiency result |
| --- | ---: | ---: | --- |
| Repeated text | 5/5 | 5/5 | Similar; tagged used fewer tools and emitted less text |
| Stale recovery | 5/5 | 5/5 | Tagged used fewer calls and was materially faster/smaller |

The mechanics results remove the apparent correctness advantage from the initial
comparison. They do not establish that tagged ranges dominate every edit format;
CRLF, large-file, and multi-location edits remain untested.

## Why not a blend yet

A fallback adds schema and selection complexity. The current evidence shows no case
where exact replacement recovers a task that tagged ranges cannot, while exact costs
more on the hardest tested recovery path. Introduce automatic fallback only after a
scenario demonstrates a repeatable tagged-specific failure and the fallback fixes it.
