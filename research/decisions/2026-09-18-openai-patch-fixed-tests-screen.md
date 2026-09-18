# Fixed-test cancellation screen: advance patch to further validation

The OpenAI patch function adapter passed this fresh screen with **20.6% lower coding latency and 27.7% lower estimated cost** than tagged edit. Both implementations passed the same 52 supplied tests, external contract execution, scope checks, and independent regrading. Neither wrote tests or changed a supplied test byte.

Decision: **further-validation**, not adoption. Retain the eval-only adapter and the fixed-test scenario. Production still declares tagged edit by default. One coding pair is insufficient to establish a general advantage or overturn the earlier unrestricted screen.

## Registered comparison

[Registration](../../evals/theories/openai_patch_fixed_tests_screen.json): seed 91805, four cells (two arms × simple control and fixed-test cancellation), one run per cell, randomized adjacent-pair arm order. Maximum four launches, $6 between-run API-equivalent estimate threshold and 1500 active seconds. The existing 900-second coding timeout was retained. Advance required every correctness/activation gate, at least 10% lower coding latency, and no more than 20% higher coding cost.

The observed motivation was the earlier trial's per-item attribution: 2,088 of 2,213 extra patch-run output tokens were in test-writing calls. This trial removes test writing as a source of workload variation. It does not retrospectively identify why the earlier run wrote larger tests.

Both arms used Astra/high, normal history, local-only tools, identical initial production code and supplied tests, unchanged read/grep output, and the same syntax-check policy. The patch adapter, Python bridge and unmodified OpenAI Agents SDK 0.22.3 parser were checked byte-for-byte against the earlier archived implementation. The treatment still uses an ordinary function carrying OpenAI operation objects; native `apply_patch` and a freeform multi-file wrapper are **not** tested here.

The new `multifile_order_cancellation_fixed_tests` scenario preserves the original fixture and adds its 22 human-authored external cancellation probes to the 30 existing tests. README and task instructions explicitly prohibit adding/changing/deleting tests or other files; only existing `orders/*.py` may change. Both arms are told to use workspace-relative edit paths and the documented full unittest command. Independent external probes repeat the now-visible contract: they are independently executed, **not unseen tests**.

## Results

| Coding result | Tagged edit | Patch adapter |
|---|---:|---:|
| Original and independent correctness | Pass | Pass |
| Supplied tests passed | 52 | 52 |
| Test files/data unchanged | Yes | Yes |
| Test-writing calls / tokens | 0 / 0 | 0 / 0 |
| Elapsed time | 84.329 s | 66.980 s |
| Tool operations | 35 | 29 |
| Model calls | 10 | 8 |
| Source-edit operations | 12 | 10 |
| Read calls | 19 | 15 |
| Failed tools / mutations | 0 / 0 | 0 / 0 |
| Changed existing source files | 10 | 10 |
| Changed-source-line metric | 118 | 118 |
| Added files | 0 | 0 |
| Source-edit output tokens | 2,916 | 2,325 |
| All output tokens | 4,210 | 3,249 |
| Input tokens, cumulative | 171,944 | 108,828 |
| Cached input tokens | 141,184 | 86,016 |
| Mutation argument bytes | 11,396 | 8,981 |
| Estimated API-equivalent cost | $0.659284 | $0.476586 |

Both made two finds, one plan update and one final `python3 -m unittest discover -s tests -v` call. All six grading gates passed: supplied public tests, external contract execution, production-only scope, immutable supplied tests, preserved migration one, and observed full verification after the final mutation. Saved workspaces were copied without bytecode caches and independently regraded using the frozen grader and fresh bytecode prefixes. Supplied test/data files were additionally compared byte-for-byte against the frozen fixture.

The simple controls were tool-free and correct: tagged 1.791 s / $0.031420; patch 1.775 s / $0.031840. All actual outbound schema/prompt/model/reasoning/tool-scope checks and patch call/result replay audits passed. The four-cell campaign completed without retries or unavailable usage, at **$1.199130** estimated API-equivalent cost and **160.776 s active worker time**. Offline checks/preflight are outside active time; estimates are not a subscription bill.

## What changed in the trajectories

Unlike the earlier unrestricted pair, patch saved two model rounds here. Tagged edited imports in `orders/repository.py` and `orders/service.py` in call 6, reread their tails in call 7, then inserted the new methods in call 8. Patch grouped each file's import/body changes into one operation in call 6. This is a concrete mechanism by which multi-hunk patches can avoid subsequent tag refreshes and dependent model rounds.

Two other extra tagged reads were slices of the supplied contract tests. Both arms' first contract read reached the shared read budget; tagged subsequently requested more test context, while patch proceeded with its existing evidence. That inspection choice is another source of variation and cannot be attributed solely to the editing format.

Total output fell 22.8%, and source-edit output fell 20.3%. Zero test-writing output confirms that this trial removed the confound it targeted. The result is consistent with a useful patch advantage when test generation is held fixed, but it does not prove that test generation caused the prior reversal. Both task instructions and visible evidence changed relative to the earlier workload, and there is only one fresh coding pair.

Next justified step: a newly registered screen on fresh coding tasks before considering a broader repeated comparison or default change. Do not pool this diagnostic with the prior workload or revise its registered drop decision.

## Evidence and verification

Evidence root: `/home/tim/.local/state/lca/research/openai-patch-fixed-tests-20260918/`.

- `frozen-source-v1/` and `manifest-v1.json`: complete implementation, fixed fixture/tests/grader, intervention audits, registration and SDK license/provenance.
- `campaign-v1/`: all four original cells, workspaces, grades, raw requests/responses/transcripts, configuration, preflight and state.
- `metrics.json`, `decision.json`, `analyze.py`: per-item output attribution, tool counts and registered-gate decision. Each attributed output total reconciles to provider-reported tokens.
- `cell-0002-independent-grade.json`, `cell-0003-independent-grade.json`, `independent-workspaces/`: fresh independent grading and unchanged-test checks.
- `offline-grader-contracts.log`, `offline-check.log`, `controller.log`: verification evidence.

Frozen source SHA-256: `c4426cb69d2d8e3d3641b9112e9e78005b88e46b1777a01595c72df89b5fc32b`, verified after analysis. Live local result directory: `evals/results/openai-patch-fixed-tests-20260918-v1`.

`make check` passed 59 Lua suites plus 140 Python eval tests; campaign preflight also passed all 140 eval tests. Focused checks covered parser/core dispatch, schema/prompt/replay corruption, known-good reference with both edit receipt forms, no-op/lost atomicity, added/changed/deleted tests, and a patch after verification. No production default was changed, and the earlier rejected profiles remain unavailable.
