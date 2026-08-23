# Decision: cap Codex streaming at ten executable tool calls

Date: 2026-08-22

Decision: accepted as the production default. Passing `stream_tool_call_cap = 0`
retains an explicit uncapped escape hatch and experiment control.

## Why this was tested

Raw eval transcripts showed Codex continuing to emit dependent tool calls after
LCA's core had already reached its deterministic ten-call execution limit. The core
discarded the excess calls and asked for another turn. Stopping the provider stream
at the same semantic boundary should avoid generating and transporting work that
cannot run in that turn.

This replaced an earlier duplicate-suppression idea after code inspection showed
that the core and parallel executor already deduplicate calls. The logs prevented a
redundant implementation.

## Controlled result

The `batch_many_files` scenario requires fifteen exact file writes and reliably
crosses the boundary. Five uncapped and five cap-10 runs all passed every deterministic
gate.

| Metric (mean) | Uncapped | Cap 10 | Effect |
| --- | ---: | ---: | ---: |
| Passed | 5/5 | 5/5 | unchanged |
| Elapsed time | 33,451.8 ms | 23,960.2 ms | -28.4% |
| Provider-visible response | 3,035.2 chars | 2,203.0 chars | -27.4% |
| Transport response | 511,427.4 bytes | 388,954.6 bytes | -23.9% |
| Executed tool calls | 16.2 | 16.0 | -0.2 |
| Model calls | 4.2 | 4.0 | -0.2 |

Every capped run hit the new provider boundary; every uncapped run hit the old core
batch boundary. A production-default confirmation also passed with 16 executed tools,
four model calls, one stream-cap event, and no core batch-cap event. The trivial prompt
remained one model call with zero tools. The strengthened authentication API scenario
passed at score 100; it did not hit this cap and is therefore regression evidence,
not treatment evidence.

## Measurement caveat

Early termination can prevent the provider's final usage event from arriving. The
apparently lower prompt/output-token totals in capped cells are censored and were not
used for adoption. Transcript-derived response characters, transport bytes, wall
time, and call counts remain observable. The eval runner now reports missing usage
events explicitly.

## Safety and rollback

Only unique, complete calls to registered tools count toward the cap. The core tells
the next model turn that only the first batch was accepted and to continue from tool
results. Set the cap to zero to restore uncapped streaming.
