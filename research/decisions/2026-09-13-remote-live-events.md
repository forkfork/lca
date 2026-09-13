# Live remote activity in the local terminal

Decision: enable for the experimental handoff image after functional validation;
continue broader reliability and long-session validation. This checks display
plumbing, not a model-quality or performance hypothesis.

The previous remote view polled running/idle state and completed conversation.
It could animate locally, but could not react to individual remote tool calls
or model text while the agent was working.

The existing worker now writes display-only JSONL events from the normal agent
callbacks: text, commentary, responses, tool activity and turn completion. The
host reads new byte ranges over the existing AWS shell ingress and feeds the
normal Lua terminal renderer. The agent never waits for an attached observer.
Input IDs and sequence numbers deduplicate replay; the host retains its byte
cursor across transport reconnects. A fresh attachment restores recent history
and the current turn's available activity. Local `/tools` and `/river` controls
work while attached.

Each journal has an approximately 8 MiB display budget, with three retained
inputs and bounded individual previews. Journals are outside the project and
excluded from S3 workspace snapshots. A gap or unavailable journal falls back
to completed history; it must not suppress the final answer. This is not an
authoritative event log for execution or recovery.

## Evidence

Private evidence is under
`~/.local/state/lca/experiments/20260913-live-events/`: registration, frozen
artifact and source manifest, build result, validation harness, raw agent log,
received events, independent grade, terminal replay and final VM state.

- Built the exact ARM64 guest artifact in Docker, then created AWS image
  `lca-handoff-20260912` version `10.0` in Sydney. Snapshot creation succeeded
  with the existing AL2027 application base and 512 MiB configuration.
- One VM, maximum lifetime 600 seconds; four model requests against
  `gpt-6-astra`, reasoning `low`, with a six-request guard checked before calls.
- The fixture's `greet(name)` ignored its argument. LCA read both files,
  edited `greet.lua`, and ran `lua5.5 test.lua`. Independently rerunning the two
  assertions passed, the original test file was unchanged, and Git showed only
  the implementation modified. The grader rejected a known-bad fixture and
  accepted a known-good fixture before the paid run.
- Four tool operations: two reads, one edit and one run. The callback stream
  contained two start events and four finish events; fast batched reads emit
  completed observations. All 23 journal records reached the observer exactly
  once, including streamed text, tool results and the final answer.
- Tool events arrived while worker state was still running. The shell reader
  disconnected and reconnected at byte 5,783 during the observed active turn;
  the resumed stream exactly matched the complete guest journal.
- Launch, setup and task validation took 20.3 seconds in this small run. This
  is not a handoff-latency benchmark. AWS subsequently confirmed `TERMINATED`.
- Replayed those actual AWS events through a local PTY: tool filenames and
  final reply were visible, `/bg` detached, and terminal settings were restored.
  Separate offline tests cover continuous frames without incoming events,
  commentary deduplication, failures, partial UTF-8 records, fast commands
  completing between polls, journal retention and display-limit fallback.
- Usage: 30,395 input tokens, including 25,216 cached, and 171 output tokens.
  Estimated model equivalent: $0.085556 at the repository's configured rates
  in `evals/run.py`; this is not an AWS or subscription invoice.

Offline validation passed the full Lua/eval suite and 75 MicroVM Python tests,
plus the focused Lua event/foreground tests. An initial test invocation omitted
the LuaRocks environment and failed module discovery; rerunning with the normal
LuaRocks paths passed. The initial AWS update invocation used an unsupported
logging flag and was rejected locally before creating a version; inspecting
the CLI skeleton and correcting it allowed the single image build to proceed.

Version 10 is the configured default; version 9 remains the validated rollback.
Old versions are subject to the existing GC policy, which protects both and
every image version referenced by a nonterminated VM. Existing VMs are not
patched or restarted. GC confirmed deletion of unused versions 7 and 8 after
checking AWS usage; versions 9 and 10 remain.

## Limits

The host polls state roughly every 750 ms and available journal bytes between
input checks; network latency adds to that. Frames are local and independent of
polling. Older images retain the coarse state/history view. This run did not
exercise durable S3 checkpoints again, repeated suspension, long-running tools,
or multiple simultaneous observers; their prior behavior is preserved, not
revalidated by this short fixture. No new daemon, remote executor or control
protocol was introduced.
