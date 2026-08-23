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
lca run "add the feature" --model gpt-5.6-sol
lca repl
lca --tui
lca repl --tui
lca --tui --tui-effect filament
```

`--tui` enables an opt-in compact living-current strip: four animated activity
rows between a faint scrollback boundary and the input dock, while completed
user and assistant messages remain in normal terminal scrollback. It does not
use the alternate screen. Without that flag, the existing readline interface
and terminal output are unchanged.
Real filenames become bouncing, morphing objects with small wakes as tools read
and change them. Current plan-task names drift through more slowly, while
commands and verification remain compact signals in the same current. The TUI
requires a POSIX terminal and the sibling `lcatui` Lua rock.

The animation engine has three interchangeable treatments: `drift` (the
default sparse particle current), `filament` (a coherent spring-like current),
and `contours` (edge arcs and vortices). Choose one at launch with
`--tui-effect NAME`, set `LCA_TUI_EFFECT`, or switch live with `/effect NAME`.
Entering `/effect` by itself shows the current choice. Files, tasks, tool
identity, and failure/success state are preserved when the visual treatment is
changed.

While the model is composing hidden tool protocol, the TUI reports that work
separately from execution—for example, `model drafting edit · src/main.js ·
4.2k chars`. A tool is only shown as active after its real runtime start event.
The default drift treatment eases between sparse listening dust, a flowing
model-composition ribbon, local tool eddies, failure turbulence, and a resolving
verification pulse before settling back to dust.
After a completed turn, the resting summary shows end-to-end work time and one
rounded final model-context number, such as `✓ 48s · 56k tokens`, instead of a
raw process result such as `exit 0`.
Submitting a request sends a short text ripple through the current. When recent
file changes are followed by verification, small pulses travel from those file
objects into the verification tool. The completed time/token summary first
crystallizes from scattered characters, then remains readable until the next
request.
As crystallization completes, one short mint/gold/lilac spark ring pops around
the time/token summary and decays into dots. It only fires once on successful
completion; failures and cancellations do not celebrate.
The bar also conducts busy batches: the highest-value event in each lane keeps
its readable label while older activity falls back to faint trail particles.
Reads skim, searches scatter, edits and writes pull toward assembly, builds
pulse, and plan steps behave like waypoints.
The upper boundary is also a quiet semantic membrane. During work it carries
one current plan task or recovery state, then becomes an unlabelled line while
listening. Generic phases such as `model waiting` remain in the current rather
than being duplicated in the boundary. Failed file mutations leave a red knot
with a compact real reason;
actual read and retry events move it through refresh and retry states, and only
a successful mutation dissolves it into mint. An unresolved file failure never
receives the successful-completion spark.
When a plan advances, the previous intent sheds into faint particles while the
new task assembles from its centre in the boundary. Recovery messages remain
immediate rather than molting. Typing in the input dock smoothly lowers visual
motion to a calm metabolic idle and releasing or submitting the text wakes the
current again; tool timing, event expiry, and execution are never slowed.

GPT-5.6 Sol uses native Responses function calling by default. This keeps LCA's
Lua tool execution and tagged-edit safety while avoiding XML-emulated tool
calls. Use `--xml-tools` to compare or temporarily fall back; `--native-tools`
can opt another Codex model into the same adapter.

Useful REPL commands: `/help`, `/status`, `/model`, `/reasoning`, `/clear`,
`/exit`. In TUI mode, `/effect` and `/effect NAME` inspect or change the
animation treatment.

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
