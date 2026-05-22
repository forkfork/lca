# LCA

> A scrappy, from-scratch Lua coding absurdity — because sometimes you want to understand every byte between you and the model.

This project reimplements the OpenAI Codex subscription OAuth flow in pure Lua, mirroring:

- `packages/ai/src/utils/oauth/openai-codex.ts`

Same client ID, authorize URL, token URL, scope, redirect URI, PKCE S256 challenge, localhost callback, token refresh, and `chatgpt_account_id` JWT extraction — no Node, no Python, just Lua and a handful of system utilities.

## Requirements

Keep it minimal:

- `lua` — the runtime
- LuaSocket — for OAuth callback handling and streaming helpers
- `lua-cjson` — JSON encoding/decoding
- `luv` — libuv bindings for async process and terminal handling
- `linenoise-luv` — optional, for readline-style REPL input
- `curl` — HTTP heavy-lifting
- `openssl` — PKCE code challenge generation

## License

BSD 2-Clause. See `LICENSE`.

Lua dependencies can be installed through LuaRocks:

```bash
luarocks install luasocket
luarocks install lua-cjson
luarocks install luv
luarocks install linenoise-luv # optional REPL line editing
```

### macOS with Homebrew

```bash
brew install lua luarocks curl openssl

luarocks install luasocket
luarocks install lua-cjson
luarocks install luv
luarocks install linenoise-luv # optional REPL line editing
```

Make sure LuaRocks-installed commands are on your shell path:

```bash
eval "$(luarocks path --bin)"
```

To persist that for zsh:

```bash
cat >> ~/.zprofile <<'EOF'
eval "$(luarocks path --bin)"
EOF
```

## Install

From a checkout:

```bash
luarocks make lca-dev-1.rockspec
eval "$(luarocks path --bin)"
```

That installs the `lca` wrapper:

```bash
lca
lca repl --model gpt-5.4-mini
lca run "Explain what files this project should inspect first."
lca login openai --out credentials.json
```

## Login

Kick things off:

```bash
cd lca
lua scripts/auth.lua login --out credentials.json
```

The script prints the authorize URL, pops it open with `xdg-open` (or your platform equivalent), spins up a tiny listener on `127.0.0.1:1455/auth/callback`, and waits. If the browser redirect doesn't land in time, it falls back to a paste prompt on stdin.

Tweak the timeout with `PI_OAUTH_CALLBACK_TIMEOUT_SECONDS` (default: `120`).

## Refresh

```bash
lua scripts/auth.lua refresh '<refresh-token>' --out credentials.json
```

Output shape:

```json
{
  "access": "...",
  "refresh": "...",
  "expires": 1760000000000,
  "accountId": "..."
}
```

## Simple Request

Prove it works in one shot:

```bash
lua examples/simple_request.lua credentials.json "Reply with exactly: oauth works"
```

Swap models on the fly:

```bash
lua examples/simple_request.lua credentials.json "Say hi" --model gpt-5.4-mini
```

## Coding Absurdity

The beating heart lives under `lua/agent/` — a growing set of modules that wire up tool dispatch, conversation state, and streaming responses. Try the one-shot CLI:

```bash
lua bin/agent.lua "Explain what files this project should inspect first." --model gpt-5.4-mini
```

See `docs/architecture.md` for the intended module layout and where this is all headed.

## REPL

The interactive mode — where the fun happens:

```bash
lua bin/repl.lua --model gpt-5.4-mini
```

If `linenoise` is installed via LuaRocks you get readline-style editing, arrow-key history, and persistent history in `.pi-lua-history`. Without it, plain `io.read` keeps things moving.

The system prompt mirrors pi's shape: coding guidance, tool descriptions, project context scraped from ancestor `AGENTS.md`/`CLAUDE.md` files, current date, and working directory — all stitched together before the first turn.

Slash commands for when you need to steer:

```text
/help
/status
/explain [path]
/model <id>
/credentials <path>
/clear
/exit
```

The tool loop supports read-only inspection tools:

```text
<tool_call name="ls">
{"path":"."}
</tool_call>

<tool_call name="read">
{"path":"lua/agent/core.lua","offset":1,"limit":120}
</tool_call>
```

Exact-replacement edits (surgical precision):

```text
<tool_call name="edit">
{"path":"example.lua","oldText":"print(\"old\")\n","newText":"print(\"new\")\n"}
</tool_call>
```

`oldText` must match exactly once in the target file — no ambiguity allowed.

Whole-file creation when you just need something to exist:

```text
<tool_call name="write">
{"path":"/tmp/hello.lua","content":"print(\"hello world\")\n"}
</tool_call>
```

Shell out when you need to:

```text
<tool_call name="run">
{"command":"lua /tmp/hello.lua"}
</tool_call>
```

Project explanation has a happy path — point it at a directory and let the loop figure out what's going on:

```text
/explain
/explain /path/to/project
```

Under the hood it injects a tool-first read-only inspection prompt, letting the model explore with `ls`, `find`, `read`, and `grep` before summarising.

## Credits

The tag-based read/edit tool design is inspired by Salvatore Sanfilippo
(@antirez), especially the discussion in
[Alternatives for the EDIT tool of LLM agents](https://antirez.com/news/166).
