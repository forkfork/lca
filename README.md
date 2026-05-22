# LCA

> A scrappy, from-scratch Lua coding absurdity — because sometimes you want to understand every byte between you and the model.

This project reimplements the OpenAI Codex subscription OAuth flow in pure Lua, mirroring:

- `packages/ai/src/utils/oauth/openai-codex.ts`

Same client ID, authorize URL, token URL, scope, redirect URI, PKCE S256 challenge, localhost callback, and `chatgpt_account_id` JWT extraction — no Node, no Python, just Lua and a handful of system utilities.

## Yolo Mode

LCA does **not** prompt for permission before running tools. If the model emits
tool calls, LCA will read files, edit files, write files, and run shell commands
directly in the current working directory.

Run it only in a repo/worktree where you are comfortable with that behavior.
Commit or stash important work first.

## Happy Path: macOS + LuaRocks

Assuming you are on macOS with Homebrew:

```bash
brew install lua@5.5 luarocks curl openssl

LUA_PREFIX="$(brew --prefix lua@5.5)"
luarocks install --local --lua-dir="$LUA_PREFIX" lca
eval "$(luarocks --local --lua-dir="$LUA_PREFIX" path --bin)"

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
LUA_PREFIX="$(brew --prefix lua@5.5)"
eval "$(luarocks --local --lua-dir="$LUA_PREFIX" path --bin)"
EOF
```

## Install

On macOS, the intended install path is:

```bash
brew install lua@5.5 luarocks curl openssl

LUA_PREFIX="$(brew --prefix lua@5.5)"
luarocks install --local --lua-dir="$LUA_PREFIX" lca
eval "$(luarocks --local --lua-dir="$LUA_PREFIX" path --bin)"
```

LuaRocks installs LCA and its Lua dependencies, including readline-style REPL
input via `linenoise-luv`.

### Linux

Install Lua, LuaRocks, curl, and OpenSSL with your distro package manager. On
Debian or Ubuntu:

```bash
sudo apt install lua5.4 luarocks curl openssl

luarocks --lua-version=5.4 --local install lca
eval "$(luarocks --lua-version=5.4 --local path --bin)"
```

### From a checkout

```bash
luarocks --local make lca-dev-1.rockspec
eval "$(luarocks --local path --bin)"
```

## Usage

```bash
lca
lca run "explain this project"
lca run "explain this project" --model gpt-5.5 --reasoning low
lca repl --model gpt-5.5 --reasoning low
```

On first run, `lca` checks for `~/.lca-credentials.json`. If it is missing,
it prompts you to choose Codex/OpenAI OAuth or Bedrock/AWS, then writes the
credentials file there.

You can also run the login flow explicitly:

```bash
lca login openai
lca login bedrock
```

Useful REPL commands:

```text
/help
/status
/model gpt-5.5
/reasoning low
/explain
/clear
/exit
```

## Local Development

Run directly from the checkout:

```bash
lua bin/agent.lua "Explain what files this project should inspect first." --model gpt-5.5
lua bin/repl.lua --model gpt-5.5
```

See `docs/architecture.md` for the module layout.

## License

BSD 2-Clause. See `LICENSE`.

## Credits

The tag-based read/edit tool design is inspired by Salvatore Sanfilippo
(@antirez), especially the discussion in
[Alternatives for the EDIT tool of LLM agents](https://antirez.com/news/166).
