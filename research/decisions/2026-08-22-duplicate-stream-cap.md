# Decision: stop Codex streams after three duplicate tool calls

Date: 2026-08-22

Decision: accepted as the production default. Setting
`stream_duplicate_call_cap = 0` explicitly restores uncapped behavior.

## Why this was tested

Raw agent-loop transcripts on tiny edit tasks contained as many as 33 complete tool
calls in one response, most exact duplicates. LCA's core correctly discarded them,
but only after the provider had generated and transported the entire response. The
treatment stops the stream at the third duplicate complete, valid call, preserves the
unique executable prefix, and tells the next model turn to continue if work remains.

## Controlled result

Five control and five capped runs were interleaved for each of `repeated_text_edit`
and deterministic `stale_edit_recovery`. All 20 runs passed every correctness,
concurrent-change, and scope gate. Five of the ten treatment runs hit the cap.

| Scenario / metric (mean) | Uncapped | Cap 3 | Effect |
| --- | ---: | ---: | ---: |
| Repeated: elapsed | 11,148 ms | 12,245 ms | +9.8% |
| Repeated: transport bytes | 248,953 | 248,187 | -0.3% |
| Repeated: model / tool calls | 3.2 / 2.0 | 3.4 / 2.0 | +0.2 / 0 |
| Stale: elapsed | 31,422 ms | 18,927 ms | -39.8% |
| Stale: transport bytes | 521,304 | 403,916 | -22.5% |
| Stale: model / tool calls | 6.2 / 3.8 | 5.6 / 3.6 | -0.6 / -0.2 |
| Stale: maximum elapsed | 49,064 ms | 24,801 ms | -49.4% |

The repeated-text case is a negative result for speed: it was essentially flat in
transport and about one second slower on average. Adoption is based on eliminating
the observed duplicate-flood tail in stale recovery without correctness loss or a
material general-case tax, not on claiming every capped request is faster.

A production-default confirmation then passed the trivial prompt in one model call
with zero tools. A stale-recovery confirmation hit the cap, preserved the concurrent
annotation, passed behavior and scope checks, and completed with three executed tools.

## Safety and measurement caveats

Only duplicate complete calls to registered tools count. Unique calls are retained,
and the next turn receives explicit continuation guidance. A useful unique call could
still have appeared later in a truncated stream, so correctness gates and the zero
rollback remain important as the scenario corpus grows.

As with the ten-unique-call stream cap, intentional cutoff can suppress the final
provider usage event. Token totals for capped calls are censored; decisions use
transcript characters, transport bytes, elapsed time, and actual call counts.
