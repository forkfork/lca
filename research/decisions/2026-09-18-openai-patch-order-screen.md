# OpenAI patch versus tagged edit: keep tagged edits

The patch adapter worked, but missed the registered performance gate. On the expanded `multifile_order_cancellation` fixture, both implementations passed every correctness gate and independent regrading. Patch used fewer tool calls, took **21.7% longer**, and cost **18.5% more** in standard API-equivalent estimates. This is one coding pair, not evidence that contextual patches are inherently slower.

Decision: **drop this implementation from active runtime; retain tagged edit as the default**. The full experimental implementations, tests, source snapshots, registrations, raw protocol, workspaces and original/regraded results are preserved externally. The unrelated empty-usage metrics crash found during the experiment is fixed in the active harness.

## What was tested

Both arms used Astra/high, normal history, local-only tools, the same version-2 fixture and independent grader, unchanged tagged read/grep, and the existing syntax-check policy. `write`, command execution and job tools remained available. Actual outbound requests were audited for exact schema and prompt transformations; source write/shell bypasses were checked separately.

The treatment replaced `edit` with an `apply_patch` function whose JSON arguments mirror OpenAI operation objects: `type` (`update_file`, `create_file`, `delete_file`), `path`, and `diff` where required. It used the **unmodified OpenAI Agents SDK 0.22.3 V4A parser**, with four editing-instruction substitutions. Multiple hunks were parsed and syntax-checked before a file write. It did not implement the multi-file `*** Begin Patch` freeform wrapper.

The [official native API contract](https://developers.openai.com/api/docs/guides/tools-apply-patch) was attempted first. LCA's configured Codex endpoint rejected `{"type":"apply_patch"}` with HTTP 400, `Unsupported tool type: apply_patch`, on the first simple control. No coding run started in that registration. The ordinary-function compatibility adapter was a **fresh registration**, not a replacement cell. This experiment therefore does not compare the unavailable native API or establish any model-training claim.

## Registered screen and results

The [native registration](../../evals/theories/openai_patch_order_screen.json) used seed 91803; the [repaired function-adapter registration](../../evals/theories/openai_patch_function_order_screen.json) used seed 91804. Each allowed four runs, a $6 between-run estimate threshold and 1500 active seconds. The repaired screen completed all four cells. Its advance gate required all correctness/protocol checks, at least 10% faster coding, and no more than 20% higher coding cost. Screens cannot establish adoption.

| Cancellation result | Tagged edit | OpenAI patch adapter |
|---|---:|---:|
| Original and independent correctness | Pass | Pass |
| Elapsed time | 150.327 s | 183.000 s |
| Tool operations | 34 | 31 |
| Model calls | 9 | 9 |
| Source edit operations | 14 tagged edits | 10 update patches |
| New-test file operations | 1 write | 2 create patches |
| Failed tools / mutations | 0 / 0 | 0 / 0 |
| Changed existing source files | 10 | 10 |
| Grader changed-source-line metric | 119 | 122 |
| Added test lines | 272 | 392 |
| Observed full-suite tests | 39 | 43 |
| Input tokens, cumulative | 142,775 | 149,911 |
| Cached input tokens | 114,560 | 118,784 |
| Output tokens | 7,596 | 9,809 |
| Mutation argument bytes | 25,961 | 33,705 |
| Summed mutation tool durations | 355 ms | 531 ms |
| Estimated API-equivalent cost | $0.776510 | $0.920504 |

Both arms made 15 reads, two finds, one plan update and one run of `python3 -m unittest discover -s tests -v`. Every external gate passed: public regressions/examples, hidden cancellation contract, scope, added tests, immutable version-one migration, and full verification after the final mutation. Both saved workspaces were copied without bytecode caches and regraded using the frozen grader with fresh bytecode prefixes.

The simple controls both answered correctly with zero tools and one model call: tagged 1.834 s / $0.031440; patch 1.763 s / $0.031830. Every actual request passed the schema, prompt, model/reasoning and tool-scope audits. Patch payloads and results were verified in subsequent function-call history.

The repaired campaign cost estimate was **$1.760284**, with **343.430 s active worker time**. The failed native registration adds **3.819 s worker time** and one attempted model invocation with **unavailable usage/cost**, not a measured zero. It attempted WebSocket transport and received the explicit rejection on HTTP fallback. Offline tests and preflight are excluded from active worker time; these estimates are not a Codex subscription bill.

## Interpretation and limits

Patch consolidated four source edit operations, but did not reduce model rounds. The patch run also wrote 120 more test lines and ran four more tests. Output tokens grew 29.1%, and mutation payload bytes grew 29.8%; the measured parser/tool-time difference was only 176 ms. This is consistent with extra generation contributing to the longer run, but one stochastic pair cannot separate test-writing variation, patch verbosity and model strategy.

The cost gate passed narrowly; the speed gate failed. Do not promote or keep an active experimental switch based on fewer calls. A future investigation could use fresh tasks and matched test-writing requirements to distinguish edit-format overhead from differing implementation/test plans. It would require a new registration; rerunning until a favorable sample is not validation.

## Evidence and verification

Evidence root: `/home/tim/.local/state/lca/research/openai-patch-order-20260918/`.

- `frozen-source-v1/`, `campaign-v1/`, `manifest-v1.json`: rejected native transport, unchanged original evidence.
- `failed-attempt-v1.json`, `recovered-metrics-v1.json`: classification and recovered diagnostics, unavailable costs explicitly marked null.
- `frozen-source-v2/`, `campaign-v2/`, `manifest-v2.json`: complete adapter implementation, SDK license/provenance, tests, all four cells, actual requests, responses, transcripts, grades and workspaces.
- `metrics-v2.json`, `cell-0002-independent-regrade-v2.json`, `cell-0003-independent-regrade-v2.json`, `regrade-workspaces-v2/`, `analyze_v2.py`: analysis and independent artifact verification.
- `offline-check-v2.log`: `make check` passed 59 Lua suites plus 137 Python eval tests. Campaign preflight independently passed the same 137 eval tests.

Frozen source hashes:

- Native v1: `9c02b37c1296881baeef423a004116dff21ad5bf9edc4817522875de82af3136`.
- Adapter v2: `1804daa3cb82158dcc3c83c17c87938a57861887241567bf58329198867f588f`.

Local result directories are `evals/results/openai-patch-order-20260918-v1` and `evals/results/openai-patch-order-20260918-v2`. Historical registrations intentionally remain; their retired editing profiles cannot execute in the active harness. Reproduction requires the preserved source and a fresh campaign registration.

Focused offline checks covered failed multi-hunk patches leaving bytes unchanged, invalid syntax, create/delete/existence errors, CRLF preservation, real core dispatch and deferred reads, outgoing schema/prompt/payload/result mismatches, source-write/shell bypasses, and patch mutations invalidating earlier test receipts. Both rejected runtime implementations and their switches were removed after preservation. After cleanup, `make check` passed all 58 Lua suites and 134 Python eval tests; `final-cleanup-check.log` preserves the result. `git diff --check` also passed.

## Post-hoc explanation: most extra output was test writing

A follow-up inspection used the provider's per-item output-token attribution, matched by item ID to function-call arguments in the saved messages. Each call's attributed output sums exactly to its reported output tokens. No additional model runs were made, and the registered decision is unchanged.

| Output-token category | Tagged | Patch adapter | Difference |
|---|---:|---:|---:|
| Existing-source editing calls | 2,298 | 2,478 | +180 (+7.8%) |
| New-test writing calls | 3,993 | 6,081 | +2,088 (+52.3%) |
| All output | 7,596 | 9,809 | +2,213 (+29.1%) |

Test-writing calls account for **94.4% of the net output-token increase**. This counts entire tool-call outputs, including JSON/diff formatting; it does not isolate test content from syntax overhead. The larger test implementation (392 versus 272 lines, 13 versus nine added test methods) is the leading explanation for the higher output budget. More test code alone does not establish stronger coverage.

Summed provider-request time grew from 149.181 to 181.635 seconds, a 32.454-second difference against the 32.673-second total task difference. Mutation execution added only 0.176 seconds. Neither arm had failed edits or retries, and both needed nine model calls. Fewer individual edit operations therefore did not remove a model round.

This supports a generation-volume explanation. [OpenAI's latency guidance](https://developers.openai.com/api/docs/guides/latency-optimization) identifies output generation as a major latency contributor. It does not establish that the tool caused the model to choose larger tests: that could be treatment-induced behavior or ordinary run variation.

The source-edit token increase is consistent with contextual patches repeating surrounding/deleted text where tagged edits can specify line endpoints plus replacement content. It is modest compared with the test-writing difference. Our JSON adapter also differs from the [native patch contract](https://developers.openai.com/api/docs/guides/tools-apply-patch); [custom free-text tools](https://developers.openai.com/api/docs/guides/function-calling#custom-tools) offer another interface worth investigating if the endpoint supports it. Neither native patch performance nor a freeform multi-file patch tool was measured here, and the endpoint's native-patch rejection does not prove that custom tools are unsupported.

The best next diagnostic would hold test-writing work constant in a fresh, registered comparison—for example, provide the same complete tests to both arms and ask each to modify production code only—then separately validate performance on unrestricted coding tasks. This is a proposed design, not a claim of improvement or permission to reuse favorable cells.

Detailed attribution is preserved as `posthoc-output-attribution.json` under the evidence root. The analysis strengthens the caution about causal attribution; it does not change the original screen's failed speed gate or restore the rejected runtime switch.
