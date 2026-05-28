# lca - lua coding agent

General-purpose coding agent written in Lua. Yolo mode only; tag-based edit
tooling is more token-efficient than Codex or Claude Code, and background jobs
are built in.

## Install

macOS:

```bash
brew install lua@5.5 luarocks curl openssl cmake
LUA_PREFIX="$(brew --prefix lua@5.5)"
luarocks install --local --lua-dir="$LUA_PREFIX" lca
eval "$(luarocks --local --lua-dir="$LUA_PREFIX" path --bin)"
```

Linux:

```bash
sudo apt install lua5.4 liblua5.4-dev luarocks build-essential curl openssl libcrypt-dev
luarocks --lua-version=5.4 --local install lca
eval "$(luarocks --lua-version=5.4 --local path --bin)"
```

From a checkout:

```bash
make local
eval "$(luarocks --lua-version=5.4 --local path --bin)"
```

## Auth

Most users should choose Bedrock/AWS on first run, using their normal AWS
credentials. Codex/OpenAI OAuth and DeepSeek API keys are also supported.

```bash
lca login bedrock
lca login openai
lca login deepseek
```

Repeated `lca login <provider>` calls update the active provider and preserve
credentials for the other providers in `~/.lca-credentials.json`.

## Usage

```bash
lca
lca run "explain this project"
lca run "add the feature" --model gpt-5.5 --reasoning low
lca repl
```

Useful REPL commands: `/help`, `/status`, `/model`, `/reasoning`, `/clear`,
`/exit`.

Codex/OpenAI uses the Responses WebSocket transport by default, with HTTPS/SSE
fallback on transport failure. To force the old HTTPS/SSE path:

```bash
LCA_CODEX_WEBSOCKET=0 lca
```

## Local Development

Run directly from the checkout:

```bash
lua bin/agent.lua "Explain what files this project should inspect first." --model gpt-5.5
lua bin/repl.lua --model gpt-5.5
```

Useful development targets:

```bash
make local   # install this checkout into local LuaRocks
make rock    # pack lca-dev-1.src.rock
make test    # run all Lua tests
make check   # make local, then make test
```

See `docs/architecture.md` for the module layout.

## License

BSD 2-Clause. See `LICENSE`.

## Credits

The tag-based read/edit tool design is inspired by Salvatore Sanfilippo
(@antirez), especially the discussion in
[Alternatives for the EDIT tool of LLM agents](https://antirez.com/news/166).
