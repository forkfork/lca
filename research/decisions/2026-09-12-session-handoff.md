# Whole-session handoff: further validation

An actual local LCA TUI accepted two queued inputs while its first model turn was
running. `/background` took precedence over that queue, waited for the local turn
to complete, transferred the dirty Git workspace and session, then continued the
queue inside a 512 MiB-baseline Lambda MicroVM in Sydney.

The local turn read README.md and clamp.lua and remembered `juniper-42`. The
first remote queued prompt repaired clamp.lua, ran tests, inspected Git and
wrote that remembered label to receipt.txt. The second queued input, `/test
lua5.5 test.lua`, completed without model calls. `lca fg` then reattached to the
same worker, submitted another prompt that recalled the label into followed.txt,
and detached while it completed. All three remote input IDs completed once.

`lca collect` stopped the worker and downloaded an isolated returned directory.
Independent host checks verified both remembered-label files, the existing tests
and 9,471 exhaustive clamp cases, unchanged README/tests, preserved untracked
files, and distinct staged/unstaged versions of notes.txt. The original local
project remained unchanged. The returned session resumed in the local TUI with
the same session ID and message count, without another model call. `lca stop`
terminated the VM; AWS confirmed TERMINATED.

## Evidence and limits

The first PTY driver attempt inherited TERM=dumb and exited before any model
call or VM launch. It was corrected to xterm-256color and its log preserved.
The live driver later failed its strict JSON equality assertion after a
successful ownership transfer: the existing session loader converts empty
annotations/logprobs arrays to empty objects. A separate recorded grade confirmed
message equality after canonicalizing only those known empty-array fields;
Codex's existing provider repair made subsequent model requests work. This is
semantic restoration, not a claim of identical serialized bytes. Nonempty plan
and compaction-summary preservation were tested offline; the live local turn
finished and therefore cleared its plan through existing LCA behavior.

Accounting: local 2 model calls / 2 tools / 15,220 input and 140 output tokens;
remote 6 model calls / 7 tools / 50,583 input and 440 output tokens. The queued
/test command is an additional no-model command. OAuth and AWS dollar costs were
not measured. This is one calibration scenario, not a migration-latency or
reliability benchmark. No real failures were injected into AWS ownership
transfer; offline recovery tests cover precommit recovery and postcommit replay
refusal. Concurrent local edits, large trees, long sessions and token expiry
need broader validation.

Durable evidence and frozen source/build manifests:
`/home/tim/.local/state/lca/experiments/20260912-handoff/`.
See registration.json, context.zip, terminal.log, foreground.py/fg.log,
local-agent.log.jsonl, grade.json, accounting.json, returned/, returned-tui.log,
and terminated.json. Local checkpoint/manifest locations are recorded in the
fixture project's .lca-handoff.json. Later atomic-write hardening and the
single-project handoff guard were verified locally; the retained image is the
frozen, live-tested worker build, not an assertion of byte-identical source to
the final checkout.

## Decision and usable scope

Further validation. This proves the first portable checkpoint, ownership
transfer, queued continuation, foreground input and isolated return path.
Use [microvm/HANDOFF.md](../../microvm/HANDOFF.md) for setup and commands.
No command-level remote executor was introduced. Deployment remains isolated
in microvm/; core changes provide a generic background checkpoint and ownership
check, with an external command selected through LCA_BACKGROUND_COMMAND.

Automatic merge back into a concurrently edited checkout, mid-tool/process
migration, crash failover, auto-suspend, cloud persistence and full-screen remote
TUI are not implemented. The first handoff waits for a whole completed turn.
Collection returns a new project; the old session remains fenced to prevent
accidental replay. VM lifetime remains finite and collection alone does not
terminate billing. Credential refresh is not implemented.

The test VM was terminated. The prepared image lca-handoff-20260912 version 1.0,
its small artifact bucket, and scoped build/run IAM roles are deliberately
retained so the user can try the feature without rebuilding. No credentials are
in that image or bucket. Local configuration is ~/.config/lca/microvm.json;
the experiment configuration uses a 900-second VM maximum duration. Retained
resources incur storage charges; no test VM remains running.

## Smooth return follow-up — September 12

A subsequent single-arm functional calibration passed on prepared image version
**3.0**, AL2027, ARM64, 512 MiB in Sydney. This supersedes the earlier manual
return instructions above: installed LCA now discovers the host client without
an environment variable; `lca fg` accepts `/local`, and `lca local` performs the
same operation directly. The default and local user configuration are now
28,800 seconds, AWS's hard eight-hour maximum (running plus suspended time).
A 24-hour setting is rejected rather than silently shortened.

Evidence: `~/.local/state/lca/experiments/20260912-smooth-return/`, including
registration-live.json, frozen context3/source-manifest.json, host hashes,
terminal and model protocol logs, grade.json, accounting.json and terminated.json.
The test used a 900-second safety limit. Its three real turns took 44.7 seconds
end to end, including model work and transfer; this is not a handoff latency
benchmark. The local read-only turn remembered `cedar-83`; the remote turn fixed
clamp and wrote that label; the second queued prompt stayed unexecuted remotely
and ran after automatic local TUI reopening, writing the same label to home.txt.
The independent grader passed 9,471 clamp cases. The same session ID, queued
input, staged/unstaged notes, and a local edit made while remote were preserved.
VM `microvm-0121b216-4af3-3e81-8445-b4f2cacc418e` was confirmed TERMINATED before
local execution resumed. Image 3.0 remains prepared in the account.

The first new image attempt (2.0) failed container construction: adding LuaRocks
copy_directories required copying microvm/ before `luarocks make` in Docker.
The corrected 3.0 build succeeded. Both artifacts and the AWS failure response
are retained; the failed build made no model calls. Model usage for the successful
calibration is recorded separately for initial local, remote and returned-local
turns (2/3/3 model calls, 2/3/2 tool calls). API-equivalent estimates use the
repository's frozen pricing convention, not an asserted subscription invoice;
AWS build and snapshot charges are excluded.

Twenty Python checks and the narrow Lua background/session/TUI suites passed;
the full `make test` suite passed. Offline coverage includes disjoint text merge,
overlapping edits changing no files, staged/unstaged separation, staged deletion,
binary and executable additions, concurrent edits after planning, idempotent
application and VM termination before removing the local execution fence.
The microvm directory secret scan found no leaks.

Decision: **further validation**, with this narrow flow usable experimentally.
Return merges working files and Git staging independently, stores a recovery
transaction, restores the session/queue, confirms termination and reopens LCA.
Changing HEAD on either side still needs manual commit reconciliation; conflicting
edits stop before application. Whole-tree writes are not globally atomic; external
editors must remain idle while applying. Crash recovery, long-running jobs,
expired model credentials and the hard VM expiry still need broader validation.
Automatic suspension is not enabled. AWS traffic-idle detection alone is unsafe
for a detached working agent; any later suspend policy must use queue/turn/job
state and transparently resume before access. Suspension does not extend the
maximum VM lifetime.

The later [idle-suspension calibration](2026-09-12-idle-suspend.md) adds worker
work-state checks and automatic resume, superseding the no-auto-suspend limitation.
