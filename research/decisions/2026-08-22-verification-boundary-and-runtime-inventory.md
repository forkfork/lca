# Verification boundary and runtime inventory

Date: 2026-08-22

## Decision

Keep the paired transient/stable verification scenarios and ship the compact startup
runtime inventory. Do not add a generic retry or evidence-sufficiency instruction to
the system prompt from this result: LCA already chose the correct mutation policy in
all ten baseline runs, while remaining excess verification is a separate behavior.

## Correctness baseline

The two fixtures have the same user-facing symptom but different ground truth:

- A transient external check fails once, then the real suite passes. Correct behavior
  is investigation and verification without any mutation.
- A stable implementation defect ignores account credit. Correct behavior is a narrow
  edit to `billing/invoice.py` followed by public and hidden green checks.

LCA Sol and Codex CLI Sol each passed both cells 5/5 after auditing equivalent final
answer wording. No agent edited the transient workspace, and every stable run changed
only the intended production file after observing the failure.

## Runtime inventory treatment

The startup inventory resolves only:

```text
sh bash git make
python python3 pip pip3 uv pytest
lua luajit luarocks
node npm npx pnpm yarn
go cargo rustc
```

It scans `PATH` using executable permission checks and caches the result for the
process. It does not execute binaries or query versions. The inventory is part of the
frozen session prompt, so it remains stable across model calls and does not erode
within-session prefix caching. Changing the prompt version rebuilds older saved
prompts once.

Five runs before and after the treatment produced:

| Scenario | Inventory | Passes | Mean tools | Mean model calls | Mean verification commands | Mean latency | Mean prompt tokens |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Transient | No | 5/5 | 14.6 | 7.8 | 7.0 | 32.1 s | 59,114 |
| Transient | Yes | 5/5 | 12.6 | 7.6 | 6.0 | 29.6 s | 58,745 |
| Stable | No | 5/5 | 11.0 | 8.2 | 2.8 | 26.4 s | 64,012 |
| Stable | Yes | 5/5 | 10.0 | 7.4 | 3.0 | 24.5 s | 59,715 |

All five earlier transient runs tried unavailable bare `python`; all five inventory
runs selected `python3` directly. This is the clearest causal effect. A simple-prompt
negative control passed at score 100 with one model call and no tools.

## Performance boundary

On this machine, an in-process warm scan of 19 names over 11 PATH directories measured
roughly 0.1 ms median and 0.14 ms p95. One shell process resolving 20 names measured
about 0.25 ms, but the in-process implementation avoids that process entirely.

Version probes are intentionally excluded. `python3 --version` and `lua -v` were
sub-millisecond locally, but `luarocks --version` took about 21–25 ms, `npm --version`
31–39 ms, and `pytest --version` 61–78 ms. Versions should be queried lazily when the
active repository and task make them relevant.

## Next step

Treat repeated successful verification as its own experiment. The runtime inventory
removed the known unavailable-binary loop, but transient runs still averaged six
commands because Sol often sought additional confidence after the result was already
established. Test a narrow evidence-sufficiency treatment against both cells and a
real existing-codebase regression before changing production guidance.
