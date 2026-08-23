# Cqueues transport migration

## Recommendation

Treat cqueues/luaossl adoption as a transport migration first, not a wholesale
replacement of luv. Keep the provider-facing request contract stable and build
one alternative Codex transport using the maintained Lua 5.5 stack:

- `forkfork/cqueues` `lua55-linux`
- `forkfork/luaossl` `lua55-linux`
- pinned upstream lua-http

LCA currently uses LuaSocket and LuaSec for HTTP/WebSocket traffic. It uses luv
separately for process execution, jobs, MCP stdio, timers, UI, and session
helpers. Those process/lifecycle uses should remain out of the first slice.

## Why this is testable

The 2026-08-22 `auth_api/mental_plan` pilot completed its useful work and tests
in seven calls, then remained stuck in the final response on a reused WebSocket.
The existing WebSocket layer accepted a total deadline from the provider but did
not enforce it. Periodic control frames could therefore keep a response alive
beyond the idle timeout.

This failure supplies a concrete transport acceptance suite:

1. Absolute per-response deadline is honored even while control frames arrive.
2. Idle timeout is honored when no frames arrive.
3. A stale reused connection is discarded and recreated before retry.
4. Cancellation interrupts connect, read, and write waits.
5. Streaming response framing and usage/tool events remain byte-equivalent at
   the provider boundary.
6. Repeated requests and reconnects leave no file descriptors, sockets, or
   cqueues coroutines behind.
7. Native Sol orientation, bounded edit, and auth correctness do not regress.

## Migration boundary

The current rockspec supports Lua `>= 5.4, < 5.6`; the maintained fork test path
targets Lua 5.5 in an isolated rock tree. A spike should use the fork's existing
installer and regression suite, then prove LCA can launch against that exact
tree. Only after transport parity should the project decide whether Lua 5.5
becomes the default and whether any remaining luv ownership is worth replacing.

## Decision rule

Prefer the cqueues transport if it passes the lifecycle suite with zero leaks,
does not reduce agent-eval correctness, and makes timeout/reconnect logic
materially simpler. Do not expand the migration to jobs/MCP/UI merely to remove
the last luv dependency; require a separate failure or measured benefit for
each subsystem.
