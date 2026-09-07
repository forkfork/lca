# Astra migration and next experiments

## Scope and rationale

Move LCA's interactive default to `gpt-6-astra`; preserve the behavior prompt,
transport, cheap read-only delegates, and historical eval defaults. Add explicit
CLI model selection for rollback. Saved sessions retain the launch model and
rebuild a cached prompt when its recorded model differs.

Astra requires Responses for tools, accepts reasoning low through max (not
none), and does not accept temperature/top_p/logprobs. LCA already uses the
compatible request shape. Map legacy none/minimal to low, preserve other effort
choices, and expose max without making it the default. Async tools and mid-turn
steering are separate transport/lifecycle projects, not prerequisites for this
migration. Prompt guidance suggests testing authorized follow-through, bounded
clarification, and avoiding redundant verification. These are candidate LCA
improvements, not established gains. Source: [OpenAI migration guidance](https://developers.openai.com/api/docs/guides/latest-model).

The model card lists a 1,050,000-token context and 128,000 maximum output.
LCA keeps a conservative 922,000 input budget, then its existing compaction
reserve. Standard per-million-token estimates are $10 input, $1 cached input,
and $50 output. Requests above 272,000 input tokens double input rates and
multiply output rates by 1.5. Eval estimates apply this per request, exclude
service-tier/hosted-tool charges, and are not Codex subscription billing.
Source: [Astra model card](https://developers.openai.com/api/docs/models/gpt-6-astra).

## Validation plan (registered before live probes)

Offline: model/effort/resume/provider/context tests, per-request pricing boundary
tests, local install and complete suite. Live: one `simple_prompt` control and
one `multifile_order_cancellation` coding smoke, explicit Astra/high, at most
two runs, no automatic retries. Each run retains the scenario's tool/time cap;
this is a compatibility check, not a quality or cost comparison. Stop on access
or protocol failure. Results recorded below after execution.

## Validation results

- Local install, focused Lua session/provider/context tests, four Python metric
  tests, and the full suite passed (59 Python eval tests plus all Lua suites).
  Initial direct Lua invocations lacked the LuaRocks path; rerunning with the
  Makefile's dependency environment resolved that setup error.
- `20260905T045849Z-simple_prompt-default-1`: PASS, 100/100, one model call,
  zero tools, 3.348 seconds, $0.038682 standard-equivalent estimate.
- `20260905T045910Z-multifile_order_cancellation-default-1`: original grade
  FAIL, 90/100, 16 tools, eight model calls, 88.393 seconds, $0.458032 estimate.
  Public and hidden behavior tests passed. The only failing gate was scope:
  Astra added `tests/test_cancellation.py`. The grader rejects every added file,
  while the prompt/README forbid modifying *existing* tests, not adding tests.
  This is a contract ambiguity to resolve before comparative campaigns; the
  original grade is unchanged and is not counted as a pass here.
- The coding run chained successful unit tests with Git checks in a non-Git
  fixture, received exit 129, then used standalone syntax/whitespace checks.
  This is a concrete verification-guidance candidate, not proof of a general
  Astra failure mode.

Compatibility is confirmed through the existing Codex login, native tools and
multi-call history. Quality superiority is unproven. The interactive default is
migrated as requested; use `--model gpt-5.6-sol` for rollback. No prompt tuning,
state-only retry, or expanded campaign was performed as part of these probes.

## Follow-up experiments

First compare Sol and Astra with the same behavior prompt and reasoning on a
paired cohort. Then hold Astra fixed and test a prompt treatment that replaces
the blanket no-permission instruction with scoped autonomy and replaces the
long-conversation stopping instruction with checkpoint-and-continue behavior.
Require project-mandated checks but avoid unchanged duplicate verification.
Do not combine these changes with state-only in one causal comparison.

The most useful next infrastructure is a resumable, budgeted campaign runner
with activation/protocol smoke gates and common evidence/grading. AGENTS.md
now specifies experiment invariants; [the workflow](../../evals/EXPERIMENTS.md)
separates implemented facilities from proposed automation and outlines a
harness-owned state ledger as the next state-only candidate.
