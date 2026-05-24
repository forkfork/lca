# Codex Transport Probes

The low-level Codex transport is now production code:

- `lua/agent/net/http_transport.lua`
- `lua/agent/providers/codex.lua`

Deterministic transport coverage lives in:

```sh
lua tests/test_http_transport.lua
```

This directory intentionally keeps only a lightweight live timing probe.

## Live Timing

Run a few real Codex requests through the production provider:

```sh
LCA_RUNS=5 lua experiments/codex_transport/compare_runs.lua
```

Replay the saved session shape:

```sh
LCA_PROBE_MODE=session LCA_SESSION=.lca-session.json LCA_RUNS=5 lua experiments/codex_transport/compare_runs.lua
```

Useful knobs:

```sh
LCA_PROMPT='Reply with exactly: ok' LCA_RUNS=10 lua experiments/codex_transport/compare_runs.lua
LCA_FIRST_BYTE_TIMEOUT=10 LCA_RUNS=3 lua experiments/codex_transport/compare_runs.lua
LCA_TOTAL_TIMEOUT=30 LCA_RUNS=3 lua experiments/codex_transport/compare_runs.lua
```

Output includes status, first-byte time, total time, response bytes, final text,
and streamed text. Use this for live endpoint observation; use
`tests/test_http_transport.lua` for deterministic protocol behavior.

## Proven In Tests

`tests/test_http_transport.lua` covers:

- Content-Length responses
- chunked responses with extensions and trailers
- compressed response rejection
- malformed folded headers
- malformed chunk size
- header byte limits
- first-byte timeout
- idle timeout after headers
- cancellation while waiting for first byte
- cancellation while waiting for body after headers
- multi-megabyte request body writes

## Remaining Watch Items

- macOS certificate-store behavior
- DNS behavior if logs show stalls before connect
