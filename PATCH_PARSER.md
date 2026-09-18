# Lua patch parser

`lua/agent/patch_diff.lua` is a Lua port of OpenAI Agents SDK 0.22.3
`agents/apply_diff.py`. It runs in process, uses no external packages and launches
no interpreter. The patch tool consumes its candidate text before syntax checks
and filesystem mutation. Language-specific syntax checkers remain separate:
checking Python source can still use Python, as it did before patch support.

Upstream: https://github.com/openai/openai-agents-python/blob/v0.22.3/src/agents/apply_diff.py

License: `licenses/OPENAI_AGENTS_LICENSE`. The frozen unmodified reference (SHA-256
`bb2fd2b0f9846ab22743934c61b0886eabc59dcddacbe871e0c906a9ad23fb53`)
lives only in `research/archive/tagged-edit-20260918/evals/vendor/`.

`evals/tests/test_patch_diff_equivalence.py` compares exact candidates and errors
against that reference over deterministic edge cases and seeded generated diffs.
Coverage includes stacked anchors, EOF, overlapping hunks, whitespace matching
(including Python's Unicode whitespace set), CRLF, absent trailing newlines,
create mode, malformed input and multiple hunks. Parser fuzz scores are internal
to upstream and are not exposed by its apply_diff API or this port.

The installed packaging test runs create/update/delete with only sh and mkdir
on PATH, proving patch interpretation does not require Python or a helper binary.
Python remains a development dependency for the test suite and build scripts.
