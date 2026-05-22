# Lua Coding Absurdity Architecture

A Lua coding absurdity with a tool-use loop, streaming REPL, parallel tool execution, context compaction, and MCP server support.
\n## Directory Layout\n\n```
bin/                        CLI entrypoints only
  agent.lua                 single-shot prompt → response\n  repl.lua                  interactive REPL session\n\nlua/agent/
  core.lua                  tool loop orchestration (run_once, run_session)
  session.lua               conversation state (messages, model, cwd)
  repl.lua                  REPL logic: readline, streaming, tool-call filtering\n  commands.lua              slash commands (/help, /status, /explain, /model, /clear, /exit)
  system_prompt.lua         builds the system prompt (tools + project context + guidelines)
  project_context.lua       walks ancestor dirs for AGENTS.md / CLAUDE.md
  tool_protocol.lua         parses <tool_call> XML from model output, formats tool results
  tool_registry.lua         tool dispatch table + system prompt generation for tools
  parallel.lua              parallel tool execution via libuv (ls/find/grep run concurrently)
  compaction.lua            context window management — summarizes old messages when large
  mcp.lua                   MCP client — spawns stdio servers, JSON-RPC tool discovery
  ui.lua                    terminal UI helpers (colors, spinners, stats, tool badges)
  lint.lua                  code linting support
  async.lua                 async utilities

  providers/
    init.lua                auto-detects provider from credentials.json
    codex.lua               OpenAI Codex Responses API (SSE streaming, OAuth tokens)
    bedrock.lua             AWS Bedrock provider (Claude models)

  tools/
    ls.lua                  list directory
    read.lua                read file (with offset/limit)
    find.lua                recursive file search
    grep.lua                content search (via rg)
    edit.lua                exact-match text replacement
    write.lua               create/overwrite file
    run.lua                 execute shell command
    shell.lua               lower-level shell execution\n\n  util/
    json.lua                JSON encode/decode helpers
    fs.lua                  file I/O
    shell.lua               shell escaping / quoting
    path.lua                path resolution / manipulation\n```\n
## Core Flow

### Single-shot (`core.run_once`)\n\n1. CLI receives a user prompt.
2. `system_prompt.build()` assembles system prompt (tool descriptions + project context + date/cwd).
3. Provider sends one request; assistant text is returned.

### Tool loop (`core.run_session`)

1. REPL or `/explain` adds a user message to the session.
2. `core.run_session` sends the full message history to the provider.
3. The response is streamed token-by-token (`on_token` callback filters `<tool_call>` and `<thinking>` tags from terminal display).
4. `tool_protocol.extract_all_tool_calls` parses any tool calls from the response.
5. If no tool calls → strip XML, return final text.
6. If tool calls found:
   - Batch is capped at 6 calls, total budget is 40 per session turn.
   - `parallel.execute_batch` splits into shell tools (ls/find/grep — run concurrently via libuv) and other tools (run sequentially via registry).
   - Results are formatted and appended to the session as tool_result messages.
   - Loop back to step 2.
7. If tool budget exhausted → inject "stop using tools" message, get final response.

### Context Compaction

When the conversation grows near the context window limit (200k tokens), `compaction.compact` summarizes older messages into a structured checkpoint (Goal / Progress / Decisions / Next Steps) and replaces them, keeping recent messages (~20k tokens) intact. Uses the LLM itself to produce the summary.

### MCP Integration

If `mcp_servers.json` exists, `mcp.lua` spawns configured MCP servers as child processes, communicates via stdio JSON-RPC, discovers their tools, and registers them in the tool registry with `mcp__<server>__<tool>` naming.

## Key Design Principles\n\n- **Provider-agnostic**: Provider code knows nothing about local tools. Tools know nothing about providers.
- **XML tool protocol**: Model emits `<tool_call name="...
