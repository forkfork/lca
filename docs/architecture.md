# lca Architecture

lca is a Lua command-line coding agent. It keeps the moving parts small:
terminal entrypoints create a session, a provider streams model output, the core
loop extracts XML tool calls, and local or MCP tools return XML tool results
back into the conversation.

The default runtime is intentionally permissive. Once credentials are available,
tool calls are executed directly in the current worktree without an approval
prompt.

## Directory Layout

```text
bin/
  lca                      launcher for repl, run, login, and auth subcommands
  agent.lua                one-shot prompt entrypoint
  repl.lua                 interactive REPL entrypoint

scripts/
  login.lua                credentials setup flow
  auth.lua                 OpenAI/Codex OAuth helper

lua/agent/
  core.lua                 model/tool loop, transcript logging, tool budgets
  repl.lua                 interactive prompt, streaming display, cancellation
  commands.lua             slash commands
  session.lua              conversation state, model options, save/load
  compaction.lua           long-context summarization

  providers/
    init.lua               provider detection, credential cache/refresh
    codex.lua              OpenAI/Codex Responses API provider
    bedrock.lua            AWS Bedrock provider
    deepseek.lua           DeepSeek chat completions provider

  net/
    http_transport.lua     small HTTPS/HTTP/1.1 streaming transport for Codex

  system_prompt.lua        builds the prompt from tools and project context
  project_context.lua      loads AGENTS.md / CLAUDE.md instructions
  project_index.lua        lightweight project file index for the prompt

  tool_protocol.lua        parses tool_call XML and formats tool_result XML
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
    shell.lua              lower-level shell execution

  util/
    fs.lua                 file I/O helpers
    json.lua               JSON extraction helpers
    path.lua               path resolution
    shell.lua              shell quoting
```

## Runtime Flow

### REPL

1. `bin/lca` defaults to the `repl` subcommand and delegates to `bin/repl.lua`.
2. `bin/repl.lua` ensures credentials exist, opens a transcript log, initializes
   MCP tools from `mcp_servers.json`, then calls `agent.repl.run`.
3. `agent.repl` creates a `session`, renders the terminal UI, reads user input,
   handles slash commands, and calls `core.run_session`.
4. Streaming tokens are displayed as they arrive, but `<thinking>` blocks and
   `<tool_call>` XML are hidden from the normal terminal view.
5. After a turn completes, the assistant text is appended to the session and
   compaction may summarize older messages if the context is near the limit.

Ctrl-C has two meanings in the REPL: during an active model/tool turn it sets a
cancellation flag checked by the core loop and sequential tool runner; at an idle
prompt it exits after auto-saving the session.

### One-Shot Run

`lca run <prompt>` delegates to `bin/agent.lua`. That entrypoint creates a fresh
session, adds the prompt as a user message, calls `core.run_session`, prints the
final text, and exits. It uses the same tool loop as the REPL.

## Core Tool Loop

`core.run_session(session, on_token, on_tool, on_thinking)` owns the model/tool
turn:

1. Load the provider selected by the credentials file.
2. Build the system prompt from the tool registry, project context, project
   index, current date, and current working directory.
3. Send the full session message list to the provider.
4. Stream tokens to the caller.
5. Parse model output with `tool_protocol.extract_all_tool_calls`.
6. Ignore parsed calls whose names are not registered local tools or discovered
   MCP tools.
7. If no valid tool calls remain, strip tool XML and return final text.
8. Otherwise, append only the tool-call XML to the session, execute a capped
   batch of calls, append each `<tool_result>` as a user message, and call the
   model again.

The loop allows up to 40 tool executions per user turn and caps each model
requested batch at 6 tool calls. If the budget is exhausted, lca asks the model
to stop using tools and answer from the gathered context.

## Tool Protocol

Models call tools with XML tags:

```xml
<tool_call name="read">
{"path":"README.md"}
</tool_call>
```

Most tools put all arguments in JSON. `edit` and `write` use JSON only for
metadata and put raw file content after the JSON block:

```xml
<tool_call name="write">
{"path":"example.lua"}
print("hello")
</tool_call>
```

`tool_protocol.lua` is the boundary for this format. It extracts calls, strips
tool XML from user-visible responses, preserves only tool-call XML in assistant
history before execution, and formats results as:

```xml
<tool_result name="read" status="ok" path="README.md">
...
</tool_result>
```

The `read` and `edit` tools use short line tags to reduce accidental stale edits:
`read` emits tagged lines, and `edit` requires the matching start/end tags for
the replacement range.

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
also returned in original batch order so the core loop can append matching
`tool_result` messages to the session.

## Providers and Credentials

Providers expose a common `complete(request, on_token)` shape. The core loop does
not know whether a request is going to OpenAI/Codex or AWS Bedrock.

`providers/init.lua` reads the credentials file, detects the provider from the
`provider` field, and defaults to `codex` when no provider is specified. The
credentials file is a multi-provider object with `provider` selecting an entry
from `providers`. It also
caches credentials by mtime and refreshes expired credentials through a
`credential_process` command when configured.

Session model selection is provider-aware. If the user leaves the default model
in place and the credentials are for Bedrock, `session.lua` uses the model stored
in the credentials file or a Bedrock default.

### Provider Transport

Codex uses the internal `agent.net.http_transport` module instead of spawning
`curl`. The transport is intentionally narrow: HTTPS, HTTP/1.1, POST,
`Connection: close`, `Accept-Encoding: identity`, fixed request
`Content-Length`, chunked response decoding, bounded response diagnostics, and
structured connect/TLS/write/first-byte/idle/total deadlines. It streams SSE
chunks to `agent.providers.codex`, which parses response deltas and preserves the
existing `complete(request, on_token)` provider contract.

Bedrock currently still uses `curl` as a subprocess transport. That code remains
provider-local in `agent.providers.bedrock`; the core loop and tool execution
layers do not depend on either transport choice.

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

`session.lua` stores credentials path, model, reasoning effort, cwd, messages,
and the latest compaction summary. REPL sessions auto-save to
`.lca-session.json` when there is conversation history, and `/save` and `/load`
expose the same serialization explicitly.

`compaction.lua` estimates token usage from message text. When the session grows
past the configured context threshold, it summarizes older messages with the
current provider, keeps roughly the most recent 20k estimated tokens, and
replaces the removed history with a structured
`[Context from previous conversation]` user message.

## Prompt Construction

`system_prompt.build` assembles the prompt from:

- the static assistant instructions,
- tool usage instructions from `tool_registry.system_prompt`,
- context-window guidance,
- project-specific instruction files found by `project_context`,
- a lightweight project index from `project_index`,
- current date and cwd.

This keeps provider-specific code out of the prompt layer and keeps tool
documentation close to the registry that executes those tools.

## Extension Points

- Add a local tool by creating `lua/agent/tools/<name>.lua`, registering it in
  `tool_registry.lua`, and documenting its call shape in
  `registry.system_prompt`.
- Add a provider by implementing `complete(request, on_token)`, adding it to
  `PROVIDER_MODULES`, and teaching credential detection how to select it.
- Add an MCP server by editing `mcp_servers.json`; no Lua code is needed if the
  server implements stdio MCP tool discovery and calls.
- Add a slash command in `commands.lua` when it only changes local REPL/session
  behavior. Commands that should involve the model can append a user message and
  return `"run"`.

## Design Boundaries

- The core loop coordinates model calls and tools, but does not implement tool
  behavior or provider transport.
- Providers handle API-specific request/stream details, but do not execute tools.
- Tool protocol parsing and formatting are centralized in `tool_protocol.lua`.
- The REPL owns terminal interaction, display filtering, slash commands, and
  cancellation UX.
- Session state is plain Lua tables that serialize directly to JSON.
