# lca — lua coding agent

A small coding-agent harness, written in Lua 5.5, with a carefully made terminal
interface. The aim is simple: make working with a model feel clear, useful, and
lovely—not like watching an opaque process churn.

LCA supports **Amazon Bedrock and OpenAI** because that's what I use. If you want
the vibes but with a different provider, I recommend forking, adding your provider
support, and removing the Bedrock / OpenAI code—it'll take you about five minutes.
The model brings the reasoning. LCA provides the working environment: files,
tools, conversation state, background jobs, and a readable account of what happened.
Use it to understand a codebase, make a change, and check the result.

## A harness that gets better with use

When LCA does a poor job, I want enough evidence to fix the harness—not just
rephrase the prompt and hope. Tool calls, arguments, results, and the raw model
exchange are logged together, so a clumsy run can become a concrete repair:
find where things went wrong, replay the awkward case, and keep a regression test.
The logs are there to work from while the annoyance is still fresh.

That feedback loop is the heart of the project. Better inspection, clearer tool
results, fewer ways to make the same mistake twice. Tagged reads and edits are
one example: a replacement is tied to the source the agent actually saw.

We benchmark improvements carefully on example tasks, often running the same work
through other harnesses to see what they do better and where LCA still stumbles.
Experiment notes live in `research/`, including what we tried, what happened, and
what was worth keeping.

The terminal gets the same care. Beautiful little animations follow what the
tools are doing; they aren't a screensaver laid over the work. Activity changes
their rhythm, and failures disturb the pattern with turbulence and fractured
marks. Even the ornament should tell you something. There is room for a little
charm in a tool you spend all day with.

LCA is a personal, evolving harness, kept small enough to understand and repair.
The aim is to make each rough edge easier to notice, explain, and smooth away.

## Install

LCA needs Lua 5.5, LuaRocks, a POSIX terminal, a C compiler, and OpenSSL 3+
development headers and libraries.

### macOS

Install the Xcode command-line tools and the Homebrew prerequisites, then build
with Homebrew's OpenSSL prefix rather than an architecture-specific path:

```bash
brew install lua@5.5 luarocks curl openssl@3 cmake
LUA_PREFIX="$(brew --prefix lua@5.5)"
luarocks --lua-version=5.5 --local --lua-dir="$LUA_PREFIX" install lca OPENSSL_DIR="$(brew --prefix openssl@3)"
eval "$(luarocks --lua-version=5.5 --local --lua-dir="$LUA_PREFIX" path --bin)"
```

The native binding is tested locally on Ubuntu; macOS build verification is still
outstanding.

### Ubuntu

With Lua 5.5 and its development headers available in your package sources:

```bash
sudo apt install lua5.5 liblua5.5-dev luarocks build-essential curl libssl-dev libcrypt-dev
luarocks --lua-version=5.5 --local install lca
eval "$(luarocks --lua-version=5.5 --local path --bin)"
```

### From a checkout

For the code in this checkout rather than the published rock, install Python 3
and the prerequisites above, then:

```bash
make local
eval "$(luarocks --lua-version=5.5 --local path --bin)"
# On macOS, use this instead of plain make local:
# make local OPENSSL_DIR="$(brew --prefix openssl@3)"
```

`make local` uses `luarocks` from your PATH. Override `LUAROCKS`, `LUA`, or
`LUA_INCDIR` if your toolchain lives elsewhere. Build once before running Lua
entry points directly from the checkout.

## Start working

The default provider is Codex/OpenAI, using OAuth:

```bash
lca login
lca
```

Credentials are stored in `~/.lca-credentials.json`. Start in the project you want
to work on, then ask for an explanation, a change, or a focused investigation.

```bash
lca run "explain this project"
lca run "add the feature" --reasoning low
lca repl
```

Interactive startup is fresh. Enter `/resume` to load the previous conversation.
The latest project session lives in `.lca-session.json`; replaced sessions are
archived under `.lca-sessions/`. Resuming keeps the launch model and credentials.

### Stay in control

| Control | Purpose |
| --- | --- |
| `/help`, `/status` | Commands and current session state |
| `/reasoning` | Reasoning settings |
| `/resume`, `/clear`, `/exit` | Manage the conversation |
| **Ctrl-T** | Inspect tools, then return to the live river |
| **Tab**, **↑/↓** in inspection | Select a tool and scroll its details |
| `/tools on`, `/tools off` | Show or hide the detailed tool board |
| `/river` | Inspect recorded activity, failures, and concurrency |
| `/effect NAME` | Change the visual style |

Tool inspection retains bounded argument/result previews: all active tools and
18 completed tools, up to 8 KB of arguments and 16 KB of results per tool.
After each turn, the summary reports work time, context usage, changed files,
verification results, and prompt-cache share when available.

### Run your tests directly

Use `/test make test` to run a command without a model request or adding its output
to model context. `/test` repeats that exact command in the current session and
project directory; LCA never guesses it from repository files. A fresh session
requires selecting the command again.

Ctrl-C cancels the process group. The terminal shows exit status and bounded
output tails; full output is in the displayed job logs, subject to job pruning.
The command waits for completion or cancellation, with no automatic timeout.

## Providers and models

**Codex/OpenAI defaults to GPT-6 Astra. Bedrock defaults to GPT-5.6 Sol.**
Both use native function calling; an explicit Astra selection on Bedrock fails
clearly rather than silently switching models.

### Codex/OpenAI

Use `--model gpt-5.6-sol` (also Terra or Luna) for a comparison. Astra supports
reasoning `low`, `medium`, `high`, `xhigh`, and `max`; legacy `none`/`minimal`
settings map to `low`.

The Responses transport uses WebSockets by default, with HTTPS/SSE fallback.
To force HTTPS/SSE:

```bash
LCA_CODEX_WEBSOCKET=0 lca
```

### Amazon Bedrock

Bedrock is an alternative provider through its OpenAI-compatible Responses endpoint.
A minimal credentials profile can use your AWS environment or CLI credential chain:

```json
{
  "provider": "bedrock",
  "providers": {
    "bedrock": {
      "region": "us-east-1"
    }
  }
}
```

Save it as `~/.lca-bedrock-credentials.json` and select it with `--credentials`.
Plain `lca` prefers valid Codex/OpenAI credentials; when those are absent, it
selects a configured Bedrock profile automatically.

The Bedrock profile also accepts `apiKey`, or `accessKeyId`, `secretAccessKey`,
and optional `sessionToken`/`expiresAt`. Keep credential files private. Refreshed
CLI credentials are saved back to the profile. The AWS CLI is only needed when
using its credential chain.

The optional `model` defaults to `global.openai.gpt-5.6-sol`. Bedrock uses HTTPS/SSE
and local native tools; OpenAI's hosted web search is not available on this path.
Astra requests are rejected, including when carried by a saved session.

## The terminal experience

Pin a launch effect with `--tui-effect NAME` or `LCA_TUI_EFFECT`. Use `/effect NAME`
to change it live, `/effect manual` to stop rotation, and `/effect auto` to restore
occasional changes at safe turn boundaries.

Styles include **duet**, a two-voice model/tool counterpoint; **squall**, slate-blue
rain and small lightning flashes; and **nightfall**, a quiet braille sky. Effects
stay in the activity area rather than erasing the conversation. The status bar
shows delivered animation FPS, including stalls and excluding repaint-only draws.

## Development and diagnostics

```bash
make local   # build and install this checkout into local LuaRocks
make test    # run the test suites
make check   # local install followed by tests
make rock    # pack the rock
```

On Linux, also run `python3 tests/test_tui_pty.py` with the LuaRocks environment
loaded for real-terminal polling, backpressure, transcript writes, and clean exit.
After terminal polling changes, restart LCA in a fresh terminal.

Raw logs live under `/tmp/lca/logs`. Each readable `lca-*.log` has a matching
`.log.jsonl` containing turn context, model requests/responses, tool arguments and
results, and transport chunks before parsing. Authentication headers are excluded,
but conversation and file contents remain: treat these logs as sensitive too.
No automatic reviewer or research model runs.

The terminal runtime is in `lua/agent/ui/`; agent-facing layout and interaction are
in `lua/agent/tui.lua`. See `docs/architecture.md` for the module layout. The eval
CLI retains its historical Sol default; pass `--model gpt-6-astra` for Astra runs.

The native binding uses OpenSSL's one-shot APIs:
<https://docs.openssl.org/3.0/man3/EVP_DigestInit/> and
<https://docs.openssl.org/3.0/man3/EVP_MAC/>.

## License and credits

BSD 2-Clause, with MIT-licensed terminal UI modules. See `LICENSE`.

The tagged read/edit tool design is inspired by Salvatore Sanfilippo (@antirez),
especially [Alternatives for the EDIT tool of LLM agents](https://antirez.com/news/166).
LCA adapts the idea with start/end tags for edit ranges and bounded relocation
when both endpoints uniquely match after a line shift.
