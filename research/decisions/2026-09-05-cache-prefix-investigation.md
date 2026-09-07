# Cache-prefix investigation: no demonstrated client cache defect

The planning screen's isolated cache regression is best explained by cache reuse
failing beyond LCA's visible request construction. The evidence does not identify
the internal cause (routing, eviction, hidden context, or other backend behavior).
No production caching change is justified. We added exact-byte eval request
capture and a reusable offline audit to improve future diagnosis.

## Evidence from the original request

Source: `evals/results/20260905-astra-planning-clarity-screen/cell-0002/`.
Between requests 3 and 4, cached tokens dropped from 9600 to 3712. All 19 prior
input items remained identical and in order. Every other request field matched:
model, reasoning, instructions, tools, key, service tier, and output settings.
The recorded nested object order also matched. The transcript shows connection
reuse without a retry, and stable logged 4 KiB and 16 KiB prefix hashes.

The raw provider usage agrees with LCA's normalized count. Attribution reports
3712 cached tool-definition tokens and zero cached instruction tokens on the
miss. LCA did not merely miscount a successful hit. The roughly 6400-token
cache-hit difference against the baseline's final request represents $0.0576
under the original estimator, enough to outweigh the entire observed $0.00778
coding-cost increase. This is sensitivity arithmetic, not recoverable savings.

The exact historical wire byte sequence is not recoverable from the saved JSON:
the old recorder decoded and re-encoded request bodies. Recorded order equality
and partial raw-byte hashes are supporting evidence, not a full-byte proof.
The original timestamped /tmp/lca/logs directory is no longer present; the durable
campaign transcript and request/response artifacts were used instead.

## Historical offline audit

`evals/analyze_cache_prefix.py` inspected 197 available adjacent serialized
request/response pairs under evals/results. All preserved the previous visible
input prefix and other request values; 8 had a lower cached-token count.
All eight also preserved recorded object order. There were no cache-usage
normalization mismatches and no skipped pairs. These are a selected local
collection of historical experiments, not a population estimate of miss rate.

Several larger drops returned to the same 3712-token cached region. Two smaller
drops and a drop to zero also occurred. This is not specific to the planning
clarification. A local loop also produced 1000 byte-identical native tool-schema
serializations within one process, including garbage collections; it found no
unstable-schema serialization mechanism.

## Registered live capability probe

Registrations: `evals/theories/astra_cache_options_screen.json` and its separately
registered `_v2` successor. Custom runners: `evals/cache_probe.py` and `.lua`.
These are read-only frozen-request replays, not fresh coding tasks. They never
execute model tool calls. The intended four-cell capability screen uses the
same Astra/high/priority requests, with only documented prompt_cache_options
added in the treatment. Simple controls gate any larger-context replay. Each
cell can issue two identical requests on one connection. Per-registration
limits: $1 estimated cost, 240 active seconds, at most eight model requests,
finite socket/request deadlines, no automatic retries, and stop on rejection
or unacknowledged activation.

The first probe completed two arithmetic responses, both 391. Its new answer
checker incorrectly read response.completed.output, which this endpoint left
empty; actual answers were in response.output_item.done events. The probe halted.
We preserved its original grades, fixed the checker against the captured stream,
and stored a separate symmetric regrade. A fresh v2 registration then ran its
own baseline. No original results were replaced or excluded from accounting.

| Registration / request | Result | Cached tokens | Estimated reported cost |
| --- | --- | ---: | ---: |
| v1 baseline first | 391; original checker failed | 3712 | $0.039262 |
| v1 baseline identical repeat | 391; original checker failed | 7040 | $0.009310 |
| v2 baseline first | Pass | 3712 | $0.039272 |
| v2 baseline identical repeat | Pass | 7040 | $0.009320 |
| v2 cache-options capability | HTTP 400 | No usage supplied | Unknown |

The exact rejection was:

`Unsupported parameter: prompt_cache_options`

Both baseline requests in v2 reported prompt_cache_retention = 24h without LCA
requesting it. The repeated-request hits demonstrate cache reuse on this path;
they do not reproduce or explain the original sporadic miss. V1 and v2 used the
same deterministic baseline key; do not treat either first response as a
controlled cold-cache condition. Treatment used a separate stable key.

The treatment stopped on its first rejection. No coding-tail cells or further
cache-control variants were launched. Total completed-response cost estimate,
including the grader failure: $0.097164. Four completions and one rejected
request were attempted; the rejection supplied no usage, so no claim of zero
billing is made for it. Combined controller active time: 14.661 seconds.

## Documentation boundary

The public Responses API documentation describes implicit/explicit cache modes,
cache boundaries, and comparison diagnostics:
https://developers.openai.com/api/docs/guides/prompt-caching
https://developers.openai.com/api/reference/cli/resources/responses/methods/create

LCA uses chatgpt.com/backend-api/codex/responses, not the public API endpoint.
The live rejection means those documented options cannot be assumed available
on this path. It also prevents using comparison_response_id inside that options
object to diagnose the old miss. There is no evidence that adding longer retention
would fix it: the current response already reports 24h. This is a configured
retention value, not proof that every request must obtain a cache hit.

An earlier shared cross-session key experiment also failed to increase cache
reuse; see 2026-09-03-shared-prompt-cache-affinity.md. We did not repeat that
rejected intervention or change key scope in production.

## Changes and validation

- evals/state_context.lua now writes the serialized provider body directly,
  preserving whitespace/object order rather than decoding and re-encoding it.
  The WebSocket adapter adds only its known response.create envelope field.
- evals/analyze_cache_prefix.py reports preserved-prefix cache drops, changes
  in recorded object order, changed request fields, raw attribution, and usage
  mismatches. It explicitly avoids assigning backend causes.
- Stream-aware probe grading has captured-response regression checks and
  known-good/bad answer checks; treatment transformation tests prove only the
  intended cache-options field changes.
- Narrow audit and state-context checks passed. make check passed, refreshing
  the local install and running Lua/Python suites. The final Python suite passed
  112 tests after adding the exact-byte-capture regression test.

No production cache key, transport, retention, or model setting changed. There
were no additional paid requests after the unsupported-field rejection.

## Retained artifacts and decision

Evidence directories:
- evals/results/20260905-astra-cache-options-screen/
- evals/results/20260905-astra-cache-options-screen-v2/

These retain registration/source snapshots, exact live request records, raw
stream frames, complete response metadata, original results, separate regrade,
preflight logs, and historical-cache-audit.json. Original planning grades remain
unchanged. The capability probe is halted, not a completed efficacy study.

Treat the planning clarification's cost reversal as cache-sensitive and
unresolved noise, not an inherent cost penalty from fewer planning rounds.
Continue measuring all costs. A later cache change needs either a reproducible
client-side prefix defect or an endpoint-supported control that demonstrably
activates. For an exact root cause of this historical miss, backend diagnostics
or provider-side tracing would be required; the available evidence cannot supply it.

## Subsequent cleanup

At the user's request, the unsupported task-specific live cache probe and its
checker were archived in `research/archive/2026-09-05-planning-cache-probes.tar.gz`
and removed from the active eval tree. Historical wire_probe variants now fail
before workspace/model work. The read-only cache-prefix analyzer, byte-preserving
request capture, and regression checks remain maintained. Production cache
behavior was not changed, and the original evidence directories are untouched.
