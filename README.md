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

From a checkout (after installing Lua 5.5, LuaRocks, Python 3 and the build prerequisites above):

```bash
make local
eval "$(luarocks --lua-version=5.5 --local path --bin)"
```

The terminal UI is included in this repository; no sibling checkout or separate
`lcatui` rock is needed. `make local` uses `luarocks` from your PATH. Override
`LUAROCKS`, `LUA`, or `LUA_INCDIR` if your toolchain uses different locations.

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
requires a POSIX terminal; its runtime is bundled as `agent.ui`. It does not use
the alternate screen.

Press **Ctrl-T** to inspect running or recent tools without losing your draft.
**Tab** selects the next tool; **↑/↓** scroll arguments and result details;
**Ctrl-T** returns to the live river. Inspection retains at most 8 KB of arguments
and 16 KB of result text per retained tool (all active plus 18 completed).

### Fast TUI development

Run `lua scripts/tui-replay.lua` from a checkout for a model-free interactive
replay: concurrent tools, failed edits, recovery, command progress, completion,
and cancellation. No commands in the fixture are executed and no session is saved.
Type a draft, inspect tools, and resize your terminal while it plays.

**Ctrl-P** pauses, **Ctrl-R** restarts (preserving your draft), **Ctrl-F** cycles
0.25×–4× speed, **Ctrl-N** steps, **Ctrl-E** cycles effects, and **Ctrl-C** exits.
The runner accepts `[fixture.json] [effect]`; the default fixture is
`tests/fixtures/tui-replay.json`. Fixtures contain a sorted `events` array with
`at` (seconds), `kind` (`submit`, `tool`, `waiting`, `complete`, `cancel`), and
`event` for tool callback payloads or `text` for other events. Optional `duration`
keeps the final state visible. Playback stops advancing at the end; restart or quit.
This is an explicit replay format, not an importer for raw protocol logs.

#### Record a real interaction

Enter `/record` **before the turn you want to capture**, then use LCA normally.
Captures are automatically named in `/tmp/lca/replays/`, beside the logs and outside
 the project (temporary storage; copy captures elsewhere to keep them); the
saved path is printed. `/record off` stops; `/record status` reports status.
While recording, `/record` also reports status without starting another capture.
An explicit path still works: `/record /tmp/lca-capture.jsonl`, or launch with
`LCA_TUI_RECORD=/tmp/lca-capture.jsonl lca`. Recording is off by default.
Replay with `lua scripts/tui-replay.lua <saved-path>`.

Captures contain prompts, assistant text, tool arguments/results/progress, model
activity, completion, and cancellation. **These may include secrets and source code;
there is no automatic redaction.** Files are created exclusively with owner-only
permissions (0600), never overwritten or uploaded. Choose a trusted local directory.
Recording stops at 2 MiB with a visible warning rather than silently dropping events.
Completed JSONL records remain replayable after interruption; an incomplete final
line is ignored. Writes are immediate but not fsynced (not power-loss durable).

This records subsequent semantic events, not prior session state, keyboard input,
terminal resize history, or pixel-exact frames. Replay uses the initial effect and
your current terminal dimensions; later effect changes are not captured. Typing and
resizing during replay still work. Stopping recording leaves the agent running;
normal TUI exit closes the capture automatically.
Interactive startup is deliberately fresh: prior transcript context is not
loaded until you enter `/resume`. The latest session for the current project
remains in `.lca-session.json`; when a new session replaces it, LCA first
archives the previous one under `.lca-sessions/`.

Run `/test make test` to execute tests directly, without model requests or adding
results to model context. `/test` repeats that exact shell command in the current
session and project working directory; a fresh session requires selecting it again.
No command is inferred from repository files. Ctrl-C cancels the process group.
The terminal shows exit status and bounded stdout/stderr tails; full output stays
in the displayed durable job logs (subject to normal job pruning). This shortcut
waits until completion or cancellation; it has no automatic timeout.
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
The established styles are equally likely. Pin a launch style with `--tui-effect NAME`
or `LCA_TUI_EFFECT`; `/effect NAME` changes it live, `/effect manual` stops rotation,
and `/effect auto` restores occasional changes.

**Duet** (`/effect duet` or `lca --tui-effect duet`) is a two-voice counterpoint:
a cool model-activity phrase and a warm tool-response phrase, with independent
rests, overlapping calls, suspended failures, and a closing cadence. It follows
observable activity, not hidden reasoning. Preview without model/tool calls:
`lua scripts/tui-replay.lua tests/fixtures/tui-performance-analysis.jsonl duet`.
**Squall** joins drift, mycelium, cytoplasm, ink, and contours in normal
startup selection and automatic rotation. It has slate-blue rain, small lightning
bolts, and a brief white flash confined to the river (not the prompt or scrollback).
Select it with `/effect squall`, or preview without model/tool calls:

```bash
lua scripts/tui-replay.lua tests/fixtures/tui-performance-analysis.jsonl squall
```

**Nightfall** (`/effect nightfall`) is a quiet braille sky: a fixed silver crescent,
sparse stars with slow twinkling, and a short fading shooting star every 18 visual
seconds. It participates in startup selection and automatic rotation. Preview with
`lua scripts/tui-replay.lua tests/fixtures/tui-replay.json nightfall`.

Press **Ctrl-E** to cycle effects; the replay status shows the current name.
While paused, cycling switches immediately. Squall lives in `lua/agent/effects/squall.lua`.

The status bar always shows delivered animation FPS. It counts completed full frames,
includes stalls, and excludes repaint-only draws.
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

On Linux, also run `python3 tests/test_tui_pty.py` with the LuaRocks environment
loaded. It exercises actual terminal polling, slow-reader backpressure, complete
colored transcript writes, and Ctrl-D cleanup. Input polling must use a separately
opened terminal descriptor: polling stdin can make shared stdout nonblocking and
silently truncate river output. After upgrading an affected running session,
launch LCA in a fresh terminal to avoid inheriting the old descriptor flags.
`make local` installs LCA and its bundled terminal runtime together. UI primitives
live in `lua/agent/ui/`; agent state, layout, and interaction remain in
`lua/agent/tui.lua`. The imported UI suites live in `tests/ui/` and run as part of
`make test`. No sibling source directory is accessed during build or execution.

See `docs/architecture.md` for the module layout.

## License

BSD 2-Clause, with MIT-licensed terminal UI modules originally from lcatui. See `LICENSE`.

## Credits

The tag-based read/edit tool design is inspired by Salvatore Sanfilippo
(@antirez), especially the discussion in
[Alternatives for the EDIT tool of LLM agents](https://antirez.com/news/166).
