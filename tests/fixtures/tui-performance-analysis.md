# Recorded TUI performance analysis

Captured September 7, 2026 with `/record`, before a complete read-only analysis turn.
Source: local capture `20260907-143649-564231-1.jsonl`; the private original remains outside Git.

`tui-performance-analysis.jsonl` retains all 1,214 semantic events, original relative timestamps, initial drift effect, and end record. It includes concurrent tools, finish-only read events, deferred read results, eight review rounds, 1,175 streaming chunks, and completion. Playback lasts about 126.6 simulated seconds, including the original initial idle interval and final hold.

Private home paths were replaced consistently with `/home/demo/`; JSON was reserialized. No event payloads or timing were otherwise intentionally changed. A common credential-pattern scan found no matches; that scan is not a general guarantee of redaction. Tool results contain source excerpts from this checkout and its local lcatui dependency.

Interactive replay (no model calls, tool execution, or session writes):

```sh
lua scripts/tui-replay.lua tests/fixtures/tui-performance-analysis.jsonl
```

Ctrl-P pauses, Ctrl-N steps, Ctrl-F changes speed, Ctrl-T opens the inspector, Ctrl-C exits.

Deterministic regression:

```sh
make test TESTS=tests/test_tui_recorded_fixture.lua
```

The test consumes the entire capture with a fixed 80x24 backend and drift effect, compares styled rows at seven checkpoints under two update schedules, and asserts tool success, streaming, and completion. It uses simulated time rather than sleeps. This checks repeatability plus semantic expectations, not a frozen visual golden or real-terminal FPS. Input and resize history were not recorded.
