# Search patterns beginning with a dash

Observed during the frozen Git-facts campaign: `grep.execute` with
`pattern="--token-ttl-seconds"` fails with `rg: unrecognized flag
--token-ttl-seconds`, although a fixture contains that literal CLI option.
Isolated fixture: `/tmp/lca-grep-dash-jdWbLN/sample.txt`.

Cause: the ripgrep command quotes the pattern but omits the `--` option
terminator. Quoting prevents shell interpretation, not option interpretation by
the called program. The fallback GNU grep path already supplies the terminator.
Running the same ripgrep flags with `--` before the pattern finds the expected
line. Both ripgrep branches (with and without a glob) need the terminator.

After Git-facts completed and the unstarted calibration was deferred, a new
regression test failed on the original implementation. Both ripgrep branches
now insert `--` before the quoted pattern. All four narrow grep tests pass,
including tagged evidence with and without a glob. The fallback grep path was
already correct and remains unchanged. Keep this fix; it restores valid search
behavior without changing regex semantics or requiring a paid model trial.

This is a deterministic tool correctness issue that can provoke an unnecessary
model repair round, not evidence that the model is bad at searching. Do not claim
an unmeasured end-to-end speed percentage.

Cleanup follow-up: the first fix covered direct execution only. The normal
multi-tool executor had a second command builder that still omitted `--`.
A regression through an actual multi-command batch reproduced that failure.
Direct and batched grep now share command construction and result formatting;
the duplicated ripgrep detection and evidence formatting were removed. The
regression checks dash patterns with and without globs, missing matches, invalid
regexes, and evidence mode on/off against direct execution. The source-evidence
module is also now explicitly included in the rockspec for clean installs.
