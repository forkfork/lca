# Project orientation and GPT-5.6 decision

> **Audit notice:** The original orientation pass rates below used grader version 1,
> which prescribed exact LCA `read` calls and rejected bounded read-only shell
> discovery. Those pass rates are quarantined for model-selection purposes. Raw
> trajectories, token counts, and latency remain observational evidence. The
> corrected cross-agent result is recorded under “Audited same-fixture baseline.”

## Decision

Keep GPT-5.5 as LCA's default for now. Keep `gpt-5.6-sol` available as an experimental
model identifier, but do not add the orientation-specific prompt treatment to the
production system prompt yet. Preserve the new orientation eval and model theories as
migration gates.

Do not change automatic session restoration yet. Fresh startup substantially reduces
input context, but the controlled sample did not reproduce the real stale-claim error
or improve latency.

## Why this eval exists

A real LCA run for “what is this project?” took 15.5 seconds and claimed the full test
suite had passed. Its raw log showed two reads and two provider calls. LCA had
automatically restored an unrelated six-message session containing roughly 15k
characters of old `make test` output. The first provider response also generated more
than 800 characters of unusable prose after its tool calls before LCA cut it off; the
second call generated the grounded answer. The UI's “4 tools” display was also wrong:
only two reads executed.

The `project_orientation` fixture uses an unfamiliar Python deployment-planning CLI.
Its grader requires README and architecture evidence, the actual plan/apply operating
model, no execution or mutation, no stale verification claim, bounded exploration,
and concise synthesis. It rewards distinctive details and contributor starting files.

## Fresh versus auto-resumed context

Both GPT-5.5 variants passed 5/5 at 100. Auto-resumed history averaged 15,065 prompt
tokens; fresh context averaged 5,861, a 61.1% reduction. Fresh output used 28.2% fewer
tokens. Fresh runs were not faster in this sample: mean elapsed time was 13.6 seconds
versus 12.0 seconds. No seeded run repeated the unsupported old-test claim.

This supports a future explicit `--resume` design on context hygiene and cost grounds,
but does not yet show a reliability or latency improvement. Add more independent-prompt
scenarios before changing a longstanding persistence behavior.

## GPT-5.5 versus GPT-5.6 Sol

Under LCA's current prompt and XML tool protocol:

- GPT-5.5 passed 5/5, mean score 100, with authoritative inspection every time.
- GPT-5.6 Sol passed 1/5, mean score 55.
- Four GPT-5.6 runs made zero tool calls and omitted the core operating model.
- The apparent 3.2-second GPT-5.6 speed advantage came from skipping required work.

A narrow treatment stating that project-index metadata is navigation only and that
the first response must contain immediate README/architecture read calls improved the
registered comparison from 1/5 to 5/5. Adding a requirement for useful starting files
then passed 4/5; its failure said inspection was unavailable rather than calling the
available tools. The same conditional treatment left `simple_prompt` flat at 5/5,
one provider call and zero tools for both variants.

The independent Codex judge attempts were unevaluable because its read-only bubblewrap
sandbox could not create a namespace in this environment. Its zero scores are harness
failures and must not be interpreted as answer ratings.

## Caching and migration implications

Official OpenAI documentation says GPT-5.6 supports exact implicit and explicit cache
breakpoints, requires a stable `prompt_cache_key` for the more reliable matching,
reports cache reads and writes separately, charges cache writes at 1.25x ordinary
input, and discounts cache reads to 0.1x. LCA already sends a stable per-session
`prompt_cache_key`, so it can use improved implicit matching without changing the
request shape. LCA now records `cache_write_tokens`, although the ChatGPT-account
Codex responses in this experiment reported no write field.

Explicitly caching LCA's large stable prompt is not a one-line option: the Responses
API cannot attach a breakpoint to top-level `instructions`. LCA would need to render
the stable prompt as a developer `input_text` block, validate that request shape on
the ChatGPT-account endpoint, and decide whether implicit suffix writes are worth the
1.25x write price.

Before making GPT-5.6 the default:

1. Resolve prompt-emulated XML versus native Responses tool-call reliability.
2. Represent GPT-5.6's 1,050,000-token context window and 922,000 maximum input limit
   correctly instead of inheriting LCA's older GPT-5 fallback.
3. Compare the current reasoning effort with one level lower on representative tasks.
4. Measure cache reads, cache writes, latency, and billed-equivalent input—not cache
   percentage alone.
5. Run model comparisons across auth creation, existing-codebase edits, deterministic
   recovery, and ambiguous investigation.

The official API docs say the `gpt-5.6` alias routes to `gpt-5.6-sol`, but LCA's
ChatGPT-account Codex endpoint rejected the alias while accepting the explicit Sol
identifier. Treat that as endpoint-specific availability, not a contradiction to the
public API contract.

## Tier comparison update

A preregistered five-run-per-cell comparison extended the same orientation path to
all available tiers:

| Model | Passes | Mean score | Mean latency | Mean tools | Estimated API-equivalent cost/run |
| --- | ---: | ---: | ---: | ---: | ---: |
| GPT-5.5 | 5/5 | 100 | 13.1s | 5.0 | $0.0184 |
| GPT-5.6 Sol | 2/5 | 65 | 8.2s | 2.0 | $0.0128 |
| GPT-5.6 Terra | 4/5 | 86 | 11.5s | 3.0 | $0.0097 |
| GPT-5.6 Luna | 1/5 | 68 | 18.4s | 3.2 | $0.0019 |

Terra is the only immediate challenger, but it is not yet non-inferior on reliability
or answer usefulness. Luna's low unit price did not translate to good behavior or
latency on this path. Sol remains worth targeting because its grounded trajectories
score 100 and are fast, but routing to it before fixing the tool boundary would trade
away reliability.

The next model work should therefore be capability-based evaluation, not a global
model switch: simple direct prompts, auth/API creation, existing-codebase edits,
recovery, and ambiguous investigation. If those cells support it, LCA can offer an
explicit `fast`/`balanced`/`deep` policy mapping to Luna/Terra/Sol with fallback based
on detectable protocol failure. Do not add automatic semantic routing until those
task classes and fallback costs are measured.

The context metadata issue is now fixed: GPT-5.5 and all three explicit GPT-5.6 tiers
use a 1,050,000-token window, a 922,000 maximum input, and a 905,616-token automatic
compaction threshold after LCA's safety reserve.

## Audited same-fixture baseline

Grader version 2 separates outcome, evidence, safety, and efficiency. It accepts
semantic evidence from LCA reads or bounded read-only shell commands, allows a strong
README-only answer to pass with an evidence warning, and reserves hard failures for
materially wrong claims, mutation, unnecessary execution, unusable size, or an
inadequate core explanation. Adversarial grader tests cover each distinction.

Five fresh runs per cell used the same Rill fixture and prompt:

| Agent loop / model | Passes | Mean total | Outcome /70 | Evidence /20 | Latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| Codex CLI / Sol | 5/5 | 94.0 | 64.0 | 20.0 | 17.9s |
| LCA / GPT-5.5 | 5/5 | 85.0 | 60.0 | 15.0 | 12.2s |
| LCA / Sol | 2/5 | 52.8 | 38.0 | 6.0 | 8.1s |

Codex consistently inspected documentation, package metadata, and source, then
distinguished intended architecture from the current skeleton. LCA 5.5 remained
reliable and was faster on this small task but omitted some implementation-state or
evidence detail. Three LCA Sol runs made zero tool calls and returned shallow
project-index summaries. Their low latency is failed-work latency.

Codex's much larger reported input-token count includes its own harness and is not a
clean model-cost comparison with LCA. Use this experiment for agent-loop behavior and
answer quality, not provider billing claims.
