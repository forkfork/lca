# lca Architecture

lca is a Lua 5.5 coding agent with one interactive TUI and one non-interactive
runner for tests and evals. Codex GPT-5.6 streams native Responses function
calls; the core executes local or MCP tools and returns correlated outputs.

The default runtime is intentionally permissive. Once credentials are available,
tool calls are executed directly in the current worktree without an approval
prompt.

## Directory Layout

```text
bin/
  lca                      launcher for repl, run, login, and auth subcommands
  agent.lua                one-shot prompt entrypoint
  repl.lua                 interactive TUI entrypoint

scripts/
  login.lua                credentials setup flow
  auth.lua                 OpenAI/Codex OAuth helper

lua/agent/
  core.lua                 model/tool loop, transcript logging, tool budgets
  tui.lua                  agent UI layout, interaction, and cancellation owner
  ui/                      bundled terminal buffers, renderer, effects, POSIX backend
                           (agent.ui; no separate lcatui rock or sibling checkout)
  commands.lua             slash commands
  session.lua              conversation state and save/resume policy
  compaction.lua           long-context summarization

  providers/
    init.lua               Codex credential selection and cache
    codex.lua              OpenAI/Codex Responses API provider

  net/
    http_transport.lua     small HTTPS/HTTP/1.1 streaming transport for Codex

  system_prompt.lua        builds the prompt from tools and project context
  project_context.lua      loads AGENTS.md / CLAUDE.md instructions
  project_index.lua        lightweight project file index for the prompt

  tool_protocol.lua        formats tool evidence and handles legacy XML text
  tool_registry.lua        local and MCP tool registration/dispatch
  parallel.lua             batched tool execution
  mcp.lua                  stdio MCP client

  tools/
    ls.lua                 list directory entries
    read.lua               read files with line tags for editing
    find.lua               recursive file search
    grep.lua               content search with ripgrep
    edit.lua               tagged line-range replacement
    write.lua              create or overwrite files
    run.lua                shell command execution

  util/
    fs.lua                 file I/O helpers
    json.lua               JSON extraction helpers
    path.lua               path resolution
    shell.lua              local command execution and shell quoting
```

## Runtime Flow

### REPL

1. `bin/lca` defaults to the `repl` subcommand and delegates to `bin/repl.lua`.
2. `bin/repl.lua` ensures credentials exist, opens a transcript log, initializes
   MCP tools from `mcp_servers.json`, then calls `agent.tui.run`.
3. `agent.tui` creates a `session`, renders the terminal UI, reads user input,
   handles slash commands, and calls `core.run_session`.
4. Streaming text and structured tool activity update the living-current view.
5. After a turn completes, the assistant text is appended to the session and
   compaction may summarize older messages if the context is near the limit.

The TUI owns raw
input and an eight-row inline viewport: four animated activity rows, two
boundaries, an input row, and a status row. Completed user and assistant messages are
committed above it to normal terminal scrollback. It calls the same
`core.run_session` engine. There is no classic frontend.

Ctrl-C has two meanings in the REPL: during an active model/tool turn it sets a
cancellation flag checked by the core loop and sequential tool runner; at an idle
prompt it exits after auto-saving the session.

### One-Shot Run

`lca run <prompt>` delegates to `bin/agent.lua`. That entrypoint creates a fresh
session, adds the prompt as a user message, calls `core.run_session`, prints the
final text, and exits. It uses the same tool loop as the REPL.

## Command execution

`session.create({ executor = ... })` accepts a plain table; the default is
`agent.util.shell`. The core passes it into tool context. No executor state is
serialized with the conversation, and there is no backend mode flag or class.

`executor:run(command, opts)` returns `{ output, code }`, with stdout and stderr
combined in arrival order, matching the existing run tool. A launch failure adds
`error`; timeout/cancellation adds `timed_out`/`cancelled`. Options are `cwd`,
`timeout` in milliseconds, `cancelled` (a predicate), `progress` (a callback), and
`progress_interval_ms`. No timeout applies unless requested; the run tool still
supplies its 120-second default. `inherit_stderr` preserves the stdout-only
behavior of the existing throwing `shell.capture(command, executor)` helper.
Git guards, curl cleanup, truncation, and tool-result formatting remain in tools.

The same capability handles run, ls, find, grep (including its per-executor
ripgrep probe), and write's directory creation. Concurrent discovery batches use
optional `executor:run_async(command, { cwd = ... }, callback)`, whose callback
receives `{ output, code, error? }`; this moves the existing libuv batch helper
without changing its scheduling. An executor with only `run` works too, executing
those commands sequentially. Async implementations must deliver callbacks through
LCA's libuv loop, or synchronously.

This is a command boundary, not a remote workspace implementation. Direct file
I/O, source-evidence reads, temporary-file linting, project indexing, background
job supervision, MCP stdio processes, terminal control, and login/launcher
commands remain local. Before this change, command execution was split between
`util.shell.capture` (`io.popen`), the run tool's libuv lifecycle, the parallel
batch libuv helper, and direct grep/ls subprocess calls; the tool command paths
now share `util.shell` as their default execution capability.

A future MicroVM implementation can provide a table with `run` returning the same
result and honoring the command options. Application/session construction can
inject it using the existing `executor` option. It can optionally provide
`run_async` to retain discovery concurrency without changing those tools.
Remote file access and persistent jobs will still require separate, explicit work.

## Core Tool Loop

`core.run_session(session, on_token, on_tool, on_thinking)` owns the model/tool
turn:

1. Load the provider selected by the credentials file.
2. Build the system prompt from the tool registry, project context, project
   index, current date, and current working directory.
3. Send the full session message list to the provider.
4. Stream tokens to the caller.
5. Read structured native function calls from the provider response.
6. Ignore parsed calls whose names are not registered local tools or discovered
   MCP tools.
7. If no valid tool calls remain, return final text.
8. Otherwise, retain the correlated provider items, execute a capped batch,
   append each function output, and call the model again.

The loop allows up to 40 tool executions per user turn. General model-requested
batches are capped at 10 calls, while wholly read-only inspection batches are
capped at 7 and at 24KB of returned content. Four consecutive read-only batches
are allowed before loop steering, keeping the overall discovery envelope bounded.
If a budget is exhausted, lca asks the model to stop using tools and answer from
the gathered context.

## Tool Protocol

Models call tools through provider-native function calls. Each call carries a
name, a call ID, and JSON arguments. For example, a native `write` call supplies:

```json
{"path":"example.lua","content":"print(\"hello\")\n"}
```

The core dispatches only `_native_tool_calls` from the provider. Assistant prose
and literal XML examples inside arguments are not parsed into executable calls.
`edit` and `write` carry file content inside their JSON arguments.

`tool_protocol.lua` retains XML parsing helpers for legacy text and fixtures,
strips protocol wrappers from display text, and formats tool-result evidence.
The provider correlates native calls and outputs by call ID. XML appearing in
stored evidence is a serialization detail, not the model's tool-dispatch protocol.

The `read`, `grep`, and `edit` tools use short line tags to reduce accidental
stale edits. `read` emits tagged lines; `grep` silently upgrades matches into
bounded tagged source windows with a file snapshot receipt; and `edit` requires
the matching start/end tags for the replacement range. A focused search can
therefore go directly from `grep` to `edit` without a redundant read. Grep
evidence is restricted to source inside the working tree and capped at two
surrounding lines, eight files, twelve merged ranges, and 20 KB.

If an `edit` is rejected because its tags are stale, the failure includes a
small freshly tagged window around the requested range. The rejected edit never
writes; the fresh evidence only lets the next model turn preserve concurrent
changes and retry without a redundant read.

## Tool Execution

`tool_registry.lua` contains the local dispatch table and augments it with MCP
tools discovered at startup. Local tool names are stable:

```text
ls read find grep edit write run
```

`parallel.execute_batch` splits requested tools into two groups:

- `ls`, `find`, and `grep` can run concurrently when more than one appears in a
  batch. They are converted to shell commands and spawned with libuv.
- All other tools run through `tool_registry.execute` sequentially. This keeps
  file writes, edits, arbitrary shell commands, and MCP calls ordered.
- After a successful `edit` or `write`, later mutations to the same resolved path
  in the same batch are rejected. The model must re-read the file before making
  another edit against the changed contents.

Tool callbacks are reported to the REPL UI as each result arrives. Results are
also returned in original batch order so the core loop can append tool-result
messages carrying the corresponding native call IDs to the session.

## Providers and Credentials

The Codex provider exposes `complete(request, on_token)` to the core loop.

`providers/init.lua` reads only the Codex entry from the credentials file,
regardless of any obsolete provider selector left by an older install. The default
model is GPT-6 Astra. Tool calling is always native; the provider explicitly
rejects requests to disable it rather than falling back to XML.

### Provider Transport

Codex uses the internal `agent.net.http_transport` module instead of spawning
`curl`. The transport is intentionally narrow: HTTPS, HTTP/1.1, POST,
`Connection: close`, `Accept-Encoding: identity`, fixed request
`Content-Length`, chunked response decoding, bounded response diagnostics, and
structured connect/TLS/write/first-byte/idle/total deadlines. It streams SSE
chunks to `agent.providers.codex`, which parses response deltas and preserves the
existing `complete(request, on_token)` provider contract.


## MCP Integration

MCP support is initialized by `bin/repl.lua` before the REPL starts:

1. `tool_registry.init_mcp` calls `mcp.start`.
2. `mcp.start` reads `mcp_servers.json`, spawns each configured stdio server,
   initializes the JSON-RPC connection, and calls `tools/list`.
3. Discovered tools are exposed as `mcp__<server>__<tool>` names in the tool
   prompt and registry.
4. `tool_registry.execute` routes matching names to `mcp.call_tool`, which
   invokes `tools/call` and flattens text content blocks into a normal tool
   result.

## Session Persistence and Compaction

`session.lua` stores conversation state, reasoning effort, cwd, messages, and
the latest compaction summary. TUI sessions auto-save to `.lca-session.json`
when there is conversation history; `/save` writes explicitly and `/resume`
restores conversation state without restoring retired runtime choices.

`compaction.lua` estimates token usage from message text. When the session grows
past the configured context threshold, it summarizes older messages with the
current provider, keeps roughly the most recent 20k estimated tokens, and
replaces the removed history with a structured
`[Context from previous conversation]` user message.

## Prompt Construction

`system_prompt.build` assembles the prompt from:

- the static assistant instructions,
- native tool usage instructions from `tool_registry.native_system_prompt`,
- context-window guidance,
- project-specific instruction files found by `project_context`,
- a lightweight project index from `project_index`,
- current date and cwd.

This keeps provider-specific code out of the prompt layer and keeps tool
documentation close to the registry that executes those tools.

## Extension Points

- Add a local tool by creating `lua/agent/tools/<name>.lua` and registering its
  implementation and native argument schema in `tool_registry.lua`. Keep usage
  guidance in `registry.native_system_prompt` aligned with the schema.
- Add an MCP server by editing `mcp_servers.json`; no Lua code is needed if the
  server implements stdio MCP tool discovery and calls.
- Add a slash command in `commands.lua` when it only changes local REPL/session
  behavior. Commands that should involve the model can append a user message and
  return `"run"`.

## Design Boundaries

- The core loop coordinates model calls and tools, but does not implement tool
  behavior or provider transport.
- Providers handle API-specific request/stream details, but do not execute tools.
- The Codex provider decodes native function calls; `tool_protocol.lua` handles
  textual result formatting and legacy markup cleanup, not runtime tool dispatch.
- The TUI owns terminal interaction, display filtering, slash commands, and
cancellation UX.
- Session state is plain Lua tables that serialize directly to JSON.

The TUI records per-turn tool events in `river_trace.lua` and renders their
summary through `river_divider.lua`. `/river` exposes the last turn’s calls for
manual investigation. Raw logs remain available under `/tmp/lca/logs`; no
background research worker or replay checkpoint is created.
