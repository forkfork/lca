# Decision: reject shared cross-session prompt cache identity

## Question

Would replacing LCA's session-specific `prompt_cache_key` with one key shared by
sessions using the same model, prompt profile, and tool schema reduce cache-adjusted
input cost enough to make repeated long-form evaluations cheaper?

## Pre-registered threshold

The proposed theory required unchanged deterministic behavior and at least a 20%
reduction in median estimated input cost across successful warm long-form runs. Its
full design called for one cold primer plus five scored runs in each scenario and
variant.

Before that 60-run matrix, a two-run-per-variant activation pilot used
`general_web_research` with GPT-5.6 Sol at high reasoning. The four jobs were
randomized. Consequently the first shared-key execution carried run label 2 and the
second carried run label 1; labels were not treated as evidence of warmth.

## Result

All four runs passed at score 100 and used one model call with no local tools. The
provider reported exactly 3,712 cached tokens and zero cache-write tokens on every
run:

| Variant | Executed result | Prompt tokens | Cached | Input-cost estimate | Latency |
|---|---|---:|---:|---:|---:|
| shared key, first execution | `20260903T052544Z` | 92,301 | 3,712 | $0.355841 | 78.6 s |
| session key | `20260903T052703Z` | 101,471 | 3,712 | $0.392521 | 85.1 s |
| shared key, second execution | `20260903T052828Z` | 58,281 | 3,712 | $0.219761 | 64.2 s |
| session key | `20260903T052932Z` | 49,306 | 3,712 | $0.183861 | 40.3 s |

Raw request summaries prove that both treatment processes sent
`lca-cache-eval-sol-current-native-v1`, while the controls sent distinct generated
session keys. The system prompt was 9,689 characters in every run. Thus the proposed
causal intermediate did not activate: repeating the shared key did not increase the
cached prefix, and distinct keys did not prevent the endpoint from returning the
same cached prefix.

Across the pilot, mean estimated input cost was $0.287801 for the treatment and
$0.288191 for control, a non-discriminating reduction of about 0.14%, versus the 20%
acceptance threshold. Treatment mean latency was 71.4 seconds versus 62.7 seconds.
Prompt-token variation came from the stochastic hosted research response, not from a
cache difference.

## Decision

Reject shared cross-session cache identity. Do not expose or ship the experimental
key override. The current endpoint already reuses LCA's stable 3,712-token prefix
across distinct session keys, so another 56 expensive task runs cannot establish the
missing mechanism.

Retain the eval-only `uncached_prompt_tokens` and `estimated_input_cost_usd` metrics;
they make future context and cache experiments more legible without changing agent
behavior. A future cache experiment needs a treatment that changes the actual cached
prefix or explicit cache-breakpoint behavior, plus an execution-order-aware primer.
