# lca - lua coding agent

General-purpose coding agent written in Lua. Yolo mode only; tag-based edit
tooling is more token-efficient than Codex or Claude Code, and background jobs
are built in.

## Install

macOS:

```bash
brew install lua@5.5 luarocks curl openssl
LUA_PREFIX="$(brew --prefix lua@5.5)"
luarocks install --local --lua-dir="$LUA_PREFIX" lca
eval "$(luarocks --local --lua-dir="$LUA_PREFIX" path --bin)"
```

Linux:

```bash
sudo apt install lua5.4 luarocks curl openssl
luarocks --lua-version=5.4 --local install lca
eval "$(luarocks --lua-version=5.4 --local path --bin)"
```

From a checkout:

```bash
luarocks --local make lca-dev-1.rockspec
eval "$(luarocks --local path --bin)"
```

## Auth

Most users should choose Bedrock/AWS on first run, using their normal AWS
credentials. Codex/OpenAI OAuth is also supported for Codex subscribers.

```bash
lca login bedrock
lca login openai
```

## Usage

```bash
lca
lca run "explain this project"
lca run "add the feature" --model gpt-5.5 --reasoning low
lca repl
```

Useful REPL commands: `/help`, `/status`, `/model`, `/reasoning`, `/clear`,
`/exit`.

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
