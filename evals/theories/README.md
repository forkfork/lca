# Theory contracts

Theory manifests connect research to controlled LCA experiments. They are
pre-registration records, not summaries written after seeing results.

The causal chain is:

`source observation -> mechanism -> harness treatment -> observable outcome -> decision`

A manifest is not runnable unless every variant names an eval-driver intervention and
every scenario already has a deterministic grader. Claims about context lifecycle,
compaction, or edit formats therefore require those intervention points and scenarios
to exist before the claim can be called tested.

Do not compare unrelated prompts, models, or fixture revisions across variants. Keep
all of those fixed and change one harness variable. Use a simple scenario as a negative
control whenever a mechanism could add overhead or provoke unnecessary agent behavior.
