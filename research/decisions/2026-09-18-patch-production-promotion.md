# User-directed promotion of the patch function

The user explicitly requested archiving tagged edit and making patch the default
following the fixed-tests screen. This is a user-directed adoption decision,
not a claim that one paired screen establishes broad superiority. The registered
screen decision remains further-validation; its artifacts and reports are intact.

Evidence: [fixed-tests screen](2026-09-18-openai-patch-fixed-tests-screen.md).
One successful coding pair was 20.6% faster and 27.7% cheaper with patch. The prior
unrestricted pair favored tagged edit, largely because patch wrote more tests.
No new live model performance experiment was run for this production migration.

## Implementation

- Production advertises the tested JSON `apply_patch` function (`type`, `path`,
  `diff`) and no longer advertises or dispatches `edit`/`multi_edit`.
- V4A parsing now uses an in-process Lua port of the OpenAI Agents SDK 0.22.3
  parser. The Python helper used in the original promotion has been removed;
  no Python interpreter, helper binary, eval directory or SDK is needed to parse patches.
- Complete candidates are parsed and syntax-checked before update writes.
  Existing unchanged syntax errors remain tolerated. A reread after syntax validation detects intervening target
  changes; this is not a filesystem locking guarantee. Creation uses an exclusive
  filesystem open, so it cannot overwrite a target that appears during preparation.
- Mutations participate in dependency scheduling, verification tracking,
  compaction, UI file events, and eval grading. Cached version-30 session prompts
  are rebuilt with patch instructions. Historical tool receipts remain readable.
- Old experiment profiles fail explicitly; replay them from frozen source.
  Active graders now recognize patch mutations; large patch hunks cannot bypass
  the multi-location scenario's surgical-edit gate.
- [Tagged implementation archive](../archive/tagged-edit-20260918/README.md)
  contains code, schemas, batching, tests, experiment adapters, attribution,
  parser licensing and checksums.

## Tradeoffs

Explicit endpoint tag validation, bounded tag relocation and stale-tag diagnostic
context are retired. The upstream parser uses contextual (including whitespace
fuzzy) matching and may select the first occurrence of ambiguous text; models
must include distinguishing context. Read/grep display tags remain for now.

Multiple hunks in one operation retain all-hunk validation before writing, but
separate same-file calls in one batch are conservatively blocked after the first
successful mutation. They are no longer reordered by tagged line coordinates.

The original promotion introduced Python and a subprocess per create/update.
That dependency has since been removed in favor of the Lua port. Syntax rejection
remains, but errors lack the old tool's annotated candidate excerpt. Writes retain existing filesystem semantics: this is not a
multi-file transaction or a crash-atomic write facility.

This is a function adapter, not the native Responses apply_patch tool (rejected
by the configured endpoint during the earlier experiment), nor a freeform
Begin/End Patch wrapper. It supports create/update/delete for one file per call.

## Validation

Focused production tests exercise create/update/delete, multiple hunks and EOF,
CRLF, Unicode and quoted paths, repeated-text disambiguation, no partial writes
on a later bad hunk, syntax checks, unchanged pre-existing syntax errors, parser
failures and temporary-file cleanup, and concurrent target changes during parsing.
Fake-provider tests exercise real dispatch, dependency deferral, result replay,
and literal protocol examples in patch content. Session tests check old prompt
migration. Grader regressions check patch counting and large-hunk rejection.

An installed-only smoke test from `/tmp` successfully created, updated and
removed a file with LuaRocks modules and the installed helper, without checkout
module paths. The packaged parser's upstream SHA-256 matches the archived source.

Final verification: `make local` passed; `make test` passed all 58 Lua suites and
142 Python eval tests. `git diff --check` and archive checksum verification passed.

## Follow-up hardening

Read failures no longer mean a target is absent: lstat distinguishes missing
paths from inaccessible or existing targets, including dangling symlinks.
Updates reject failed reads and recheck source bytes after syntax validation.
Creates use exclusive open after validation and parent-directory setup.
Regression tests cover read exceptions/nil returns, stat errors, dangling links,
changes during syntax validation and targets appearing immediately before open.

The unused stale-edit-evidence session setting and multi-edit registry API are
removed. Old eval switches, including false values, now fail before reading
inputs or creating workspaces; historical manifests remain readable.
The installed-only parser smoke is automated in the packaging suite.
The multi-location grader counts removed source lines rather than unchanged
patch context, with tests for both oversized changes and generous context.

Follow-up validation passed: full `make check` (58 Lua suites, 143 Python tests).
After preserving normal umask-based creation permissions, `make local` and the
focused patch, installed packaging, and retired-option suites passed again.
Updates still use ordinary filesystem writes after their final reread; no
cross-process locking or crash-atomicity guarantee is claimed.

## Removal of the runtime Python parser

At the user's request, interpretation moved to `agent.patch_diff`, a Lua port
of the frozen SDK 0.22.3 parser. Runtime Python code, the helper binary, temporary
JSON request files and parser subprocess execution are removed from the package.
The upstream MIT license is installed under `licenses/`. The unmodified Python
reference remains in the research archive and is imported only by offline tests.

The deterministic equivalence suite compares exact candidate bytes and error
messages across more than 1,000 fixed and seeded cases, including stacked
anchors, Unicode whitespace, CRLF, EOF, malformed and multi-hunk patches.
The installed-only smoke restricts PATH to sh and mkdir, verifying that all three
patch operations work without Python or the old helper. An update test also
rejects any attempt to invoke its command executor for patch interpretation.
Language-specific syntax checking remains separate and unchanged.

The earlier live speed/cost measurements concern the Python adapter. This port
has equivalence and integration coverage; no new live performance claim is made.

Lua-port validation passed: `make local`, all 58 Lua suites and 144 Python
 development tests, including frozen-reference equivalence and the installed
 smoke without Python on PATH. The old helper is no longer installed.
