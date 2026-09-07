# lca - lua coding agent

Personal coding agent written in Lua 5.5. It has one interactive TUI, Codex
GPT-6 Astra native tools, tagged edits, and built-in background jobs.

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
sudo apt install lua5.5 liblua5.5-dev luarocks build-essential curl openssl libcrypt-dev
luarocks --lua-version=5.5 --local install lca
eval "$(luarocks --lua-version=5.5 --local path --bin)"
```

From a checkout:

```bash
make local
eval "$(luarocks --lua-version=5.5 --local path --bin)"
```

## Auth

LCA uses Codex/OpenAI OAuth only.

```bash
lca login
```

Credentials are stored in `~/.lca-credentials.json`.

## Usage

```bash
lca
lca run "explain this project"
lca run "add the feature" --reasoning low
lca repl
```

Use LCA to explore a codebase, make changes, and verify the results. Native tools
support file inspection, tagged edits, shell commands, and background jobs. For
substantial tasks, progress is tied to actual inspection, changes, and verification
rather than a guessed completion percentage.

The interactive `lca` and `lca repl` commands keep completed messages in normal
terminal scrollback, with a compact activity area above the input. Tool activity,
failures, and verification results stay visible while the agent works. The TUI
requires a POSIX terminal and the sibling `lcatui` Lua rock; it does not use the
alternate screen.

Interactive startup is deliberately fresh: prior transcript context is not
loaded until you enter `/resume`. The latest session for the current project
remains in `.lca-session.json`; when a new session replaces it, LCA first
archives the previous one under `.lca-sessions/`.

After each turn, the summary reports work time and model-context usage, plus
changed files, verification results, and prompt-cache share when available.
Use `/river` to inspect recorded tool activity, failures, concurrency, and repeated
arguments. Raw run logs are available under `/tmp/lca/logs`; no automatic reviewer
or research model runs.

Each readable `lca-*.log` has a matching `.log.jsonl` replay log. It records full
turn context, model requests/responses, tool arguments/results (including successful
inspections), and transport request bodies and response chunks before parsing.
Records include UTC timestamps, sequence numbers, turn IDs, and model/tool call IDs.
Transport chunks use `bytes_hex` so even split UTF-8 and malformed streams can be
reconstructed exactly. Authentication headers are excluded; conversation and file
contents are retained. Logging write/flush failures are reported as errors.

GPT-6 Astra with native Responses function calling is the default runtime.
Use `--model gpt-5.6-sol` (also Terra or Luna) for an explicit rollback or
comparison. Astra accepts reasoning `low`, `medium`, `high`, `xhigh`, and `max`;
legacy `none`/`minimal` settings map to `low`. Resuming restores the conversation
but keeps the launch model and credentials. Read-only delegate models remain
independently pinned. The eval CLI retains its historical Sol default: pass
`--model gpt-6-astra` explicitly for new Astra runs.

Useful TUI commands: `/help`, `/status`, `/reasoning`, `/resume`, `/clear`,
`/exit`. Use `/tools on` or `/tools off` to show or hide the detailed tool board.

Animation adds visual polish: startup picks a style at random, then usually keeps
it, with a 20% chance of changing at each safe turn boundary after the first.
All styles are equally likely. Pin a launch style with `--tui-effect NAME` or
`LCA_TUI_EFFECT`; `/effect NAME` changes it live, `/effect manual` stops rotation,
and `/effect auto` restores occasional changes.

Codex/OpenAI uses the Responses WebSocket transport by default, with HTTPS/SSE
fallback on transport failure. To force the old HTTPS/SSE path:

```bash
LCA_CODEX_WEBSOCKET=0 lca
```

## Local Development

The local development install targets Lua 5.5 by default. Override
`LUA_VERSION` only when deliberately testing another supported runtime.

Run directly from the checkout:

```bash
lua bin/agent.lua "Explain what files this project should inspect first."
lua bin/repl.lua
```

Useful development targets:

```bash
make local   # install this checkout into local LuaRocks
make rock    # pack lca-dev-1.src.rock
make test    # run all Lua tests
make check   # make local, then make test
```

`make local` first installs
`/home/tim/git/lcatui/lcatui-dev-1.rockspec`, then installs LCA. Override the
sibling checkout location when needed:

```bash
make local LCATUI_ROCKSPEC=/path/to/lcatui/lcatui-dev-1.rockspec
```

See `docs/architecture.md` for the module layout.

## License

BSD 2-Clause. See `LICENSE`.

## Credits

The tag-based read/edit tool design is inspired by Salvatore Sanfilippo
(@antirez), especially the discussion in
[Alternatives for the EDIT tool of LLM agents](https://antirez.com/news/166).
