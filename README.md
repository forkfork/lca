# LCA

> A scrappy, from-scratch Lua coding absurdity — because sometimes you want to understand every byte between you and the model.

This project reimplements the OpenAI Codex subscription OAuth flow in pure Lua, mirroring:

- `packages/ai/src/utils/oauth/openai-codex.ts`

Same client ID, authorize URL, token URL, scope, redirect URI, PKCE S256 challenge, localhost callback, token refresh, and `chatgpt_account_id` JWT extraction — no Node, no Python, just Lua and a handful of system utilities.

## Happy Path: macOS + LuaRocks

Assuming you are on macOS with Homebrew:

```bash
brew install lua luarocks curl openssl

luarocks --local install lca
eval "$(luarocks --local path --bin)"

lca
```

On first run, choose `Codex / OpenAI OAuth` when prompted. LCA opens the browser
login flow and stores credentials at:

```text
~/.lca-credentials.json
```

After that:

```bash
lca run "explain this project"
lca run "explain this project" --model gpt-5.5 --reasoning low
lca repl --model gpt-5.5 --reasoning low
```

To keep `lca` on your path in future terminals:

```bash
cat >> ~/.zprofile <<'EOF'
eval "$(luarocks --local path --bin)"
EOF
```

## Requirements

Keep it minimal:

- `lua` — the runtime
- LuaSocket — for OAuth callback handling and streaming helpers
- `lua-cjson` — JSON encoding/decoding
- `luv` — libuv bindings for async process and terminal handling
- `linenoise-luv` — optional, for readline-style REPL input
- `curl` — HTTP heavy-lifting
- `openssl` — PKCE code challenge generation

## Install

The normal install path is:

```bash
luarocks --local install lca
eval "$(luarocks --local path --bin)"
```

LuaRocks installs the Lua dependencies automatically:

- LuaSocket
- `lua-cjson`
- `luv`

Optional REPL line editing:

```bash
luarocks --local install linenoise-luv
```

### Linux with bash

Install Lua, LuaRocks, curl, and OpenSSL with your distro package manager. On
Debian or Ubuntu:

```bash
sudo apt install lua5.4 luarocks curl openssl

luarocks --lua-version=5.4 --local install luasocket
luarocks --lua-version=5.4 --local install lua-cjson
luarocks --lua-version=5.4 --local install luv
luarocks --lua-version=5.4 --local install linenoise-luv # optional REPL line editing
```

Make sure LuaRocks-installed commands are on your shell path:

```bash
eval "$(luarocks --lua-version=5.4 --local path --bin)"
```

To persist that for bash:

```bash
cat >> ~/.bashrc <<'EOF'
eval "$(luarocks --lua-version=5.4 --local path --bin)"
EOF
```

From a checkout:

```bash
luarocks --local make lca-dev-1.rockspec
eval "$(luarocks --local path --bin)"
```

On Linux, if your LuaRocks defaults to Lua 5.1, use the same Lua version flag
as above:

```bash
luarocks --lua-version=5.4 --local make lca-dev-1.rockspec
eval "$(luarocks --lua-version=5.4 --local path --bin)"
```

That installs the `lca` wrapper:

```bash
lca
lca repl --model gpt-5.4-mini
lca run "Explain what files this project should inspect first."
lca run "Explain this code" --model gpt-5.5 --reasoning low
```

## License

BSD 2-Clause. See `LICENSE`.

## Login

On first run, `lca` checks for `~/.lca-credentials.json`. If it is missing,
it prompts you to choose Codex/OpenAI OAuth or Bedrock/AWS, then writes the
credentials file there.

You can also run the login flow explicitly:

```bash
lca login openai
lca login bedrock
```

The Codex/OpenAI flow prints the authorize URL, pops it open with `xdg-open` (or your platform equivalent), spins up a tiny listener on `127.0.0.1:1455/auth/callback`, and waits. If the browser redirect doesn't land in time, it falls back to a paste prompt on stdin.

Tweak the timeout with `PI_OAUTH_CALLBACK_TIMEOUT_SECONDS` (default: `120`).

## Refresh

```bash
lua scripts/auth.lua refresh '<refresh-token>' --out ~/.lca-credentials.json
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
lua examples/simple_request.lua ~/.lca-credentials.json "Reply with exactly: oauth works"
```

Swap models on the fly:

```bash
lua examples/simple_request.lua ~/.lca-credentials.json "Say hi" --model gpt-5.4-mini
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
/reasoning <effort>
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
