# Preserve operational snapshots at cache boundaries

## Decision

Keep the user-requested repair: ordinary model requests no longer attach a
replaceable operational-state tail. Compaction embeds an immutable snapshot in
its checkpoint message; resume inserts one snapshot into persistent history.
The next compaction refreshes the snapshot, and normal tool results carry newer
observations between boundaries.

The small live screen supports the cache-boundary mechanism: the persistent
checkpoint reused 97.74% of its second request's input, versus 0% with the old
transient tail. This is not evidence of a general latency improvement or long-task
correctness gain. Broader claims require fresh validation; do not expand this
screen. The user's live session still needs restarting to load the repair.

## Observed failure

`/tmp/lca/logs/lca-20260911-172150-687550.log.jsonl`, requests `8:1` through `8:7`,
reported 7,168 cached tokens per request while input grew from 227,035 to 260,085.
Usage attribution assigned 5,132 cached tokens to tools and 2,036 to instructions,
and zero to conversation items. The completed turn's cache fraction was 2.92%.
Adjacent actual transport bodies shared their previous input items except for
the final temporary operational-state message. Raw serialized prefixes also
matched until that message. The stable cache key and settings did not change.

The [official caching documentation](https://developers.openai.com/api/docs/guides/prompt-caching)
describes an implicit breakpoint at the latest eligible message for GPT-5.6 and
later. Removing that message removes the previously written endpoint, even if
much of its earlier prefix still matches. The earlier claim that a transient
append preserved cache reuse confused stable text with a reusable cache endpoint.
An earlier endpoint-capability probe rejected `prompt_cache_options`; this repair
uses no new cache parameters.

## Repair and offline checks

- The machine-held record still observes calls, outcomes, edits and jobs, and is
  provided to the summarizer. A poor summary cannot erase the separate checkpoint
  snapshot.
- A snapshot becomes actual conversation history at compaction or resume. Its
  text is never rewritten as later calls execute.
- Ordinary requests use ordinary history with no synthetic tail. This also avoids
  repeating the entire record after every tool batch.
- Pending resume evidence counts toward context estimates until insertion; after
  insertion it is counted once as normal history.
- Internal resume snapshots are excluded when finding the latest human message
  for active-turn preservation during compaction.
- Existing historical eval interventions explicitly retain their transient
  projection, rather than silently changing the comparison they represent.

The new regression test compares actual provider input items across consecutive
requests and requires the entire previous input array to remain an identical
prefix. It also checks updated evidence at subsequent compaction and no duplicate
snapshot accounting. Existing tests cover incomplete summaries, failed outcomes,
resume, edits, tool result delivery, jobs and both historical experiment setups.
`make local` and the full Lua/Python test suite passed.

Job status in a snapshot is historical. Explicit job inspection and subsequent
tool outputs supply newer status; this change does not promise a continuously
refreshed state block between compactions. Old history may still be slimmed or
compacted by existing mechanisms, which can independently affect caching.

## Registered screen and results

Four cells: transient/persistent arms on simple arithmetic and a checkpoint
containing fixed reference text. Each cell makes two model requests. Astra/high,
priority, no tools declared to the model; actual local arithmetic checks supply
recorded outcomes. A fixed summary isolates request layout rather than summary
quality. Separate stable per-cell cache keys; randomized adjacent arms. Limits:
eight requests, $2 between-cell estimated-cost threshold, 180 seconds. Stop on
answer, activation, usage or execution failure. No controller retries.

Registered advance rule: both answers are `391`, persistent second-request cache
fraction >=70%, and >=50 percentage points above transient. Actual serialized
requests must show the persistent full prefix and transient tail mismatch.

| Scenario | Arm | First input/cached | Second input/cached | Second cache fraction | Total response time |
|---|---|---:|---:|---:|---:|
| Simple | transient | 35 / 0 | 60 / 0 | 0% | 3.508 s |
| Simple | persistent | 35 / 0 | 60 / 0 | 0% | 4.256 s |
| Checkpoint | transient | 9,801 / 0 | 9,893 / 0 | 0% | 4.209 s |
| Checkpoint | persistent | 9,797 / 0 | 9,822 / 9,600 | 97.74% | 4.778 s |

All eight answers were correct, with five output tokens each. All usage was
present; reported cache-write tokens were zero. Persistent input retained all
three previous input items; transient retained three of four, dropping its state
tail. The simple controls both retained their prior input and are too short to
qualify for caching. No general speed improvement is claimed: the persistent
checkpoint pair was slightly slower in this single sample.

Successful v3 collection cost $0.310630 standard API equivalent and took 16.981
controller seconds. This is an estimate from reported usage, not a subscription
bill. The source hashes matched the immutable manifest after collection.

## Invalid attempts and evidence

V1 failed to load `luarocks.loader` before any model call. V2, with the LuaRocks
environment restored, produced two correct simple answers and saved complete
usage, then exited with signal 11 during standalone Lua process shutdown. It
stopped as registered; cost $0.001450 and 4.721 controller seconds. Neither attempt
contributes cells to v3. V3 uses explicit process exit after evidence is flushed,
avoiding Lua-state teardown in this standalone probe; provider requests and the
production transport were not changed to address that probe failure.

All-attempt completed-response cost is $0.312080, with ten model completions total.
No usage from a sent model request is missing. Failed setup and shutdown evidence
is retained alongside the successful fresh registration; no original result was
rewritten. V3 seed is 91113, following invalid v1/v2 seeds 91111/91112.

Evidence directories under `evals/results/`:

- `20260911-cache-boundary-screen/`: registration, runner, setup failure.
- `20260911-cache-boundary-screen-v2/`: fresh registration, two responses and usage,
  raw transport, process failure.
- `20260911-cache-boundary-screen-v3/`: manifest, frozen source, all requests,
  actual provider bodies, raw transport logs, local check receipts, responses,
  accounting and final audit.

The live screen exercises the production checkpoint and request projection, but
uses a synthetic reference workload. The offline regression exercises the full
state-preservation boundaries. Neither establishes how often unrelated history
slimming or backend routing will reduce cache reuse in longer real sessions.
