# Instructions and capability loading

Status: initial synthesis, 2026-08-22.

## More instruction is not automatically more control

Anthropic reports that it removed more than 80% of Claude Code's system prompt for
its latest model generation without measurable loss on its coding evals. The stated
failure mechanism was accumulated, overlapping, and conflicting guidance across the
system prompt, project files, skills, and user requests. This is vendor-specific
evidence, but it directly challenges the idea that every observed failure should add
a permanent system rule. [claude-context-rules-2026]

A recent 288-run two-agent ablation found no measurable correctness improvement from
always-on or selectively retrieved repository context files across its 17 real tasks.
Its failure analysis attributed misses to implementation skill rather than missing
repository knowledge. This does not prove context files are useless—the task set is
small and effects are bounded rather than universally absent—but it means LCA should
measure any claimed benefit instead of treating large instruction files as free.
[context-files-ablation]

A separate repository-mining study found configuration smells widespread in 100
AGENTS.md/CLAUDE.md files, especially restating lint-enforced rules, context bloat,
skill leakage, and conflicting instructions. That study measures prevalence, not
downstream task success, so it is best used as a lint taxonomy and experiment source.
[agents-md-smells]

## Capability schemas are context too

Tool descriptions, MCP schemas, skills, and plugin instructions compete with task
evidence. Factory's deferred-context design exposes compact discovery metadata first,
then promotes full schemas/instructions only after selection. Claude Code similarly
recommends placing verbose or specialized capabilities in scoped skills/subagents
instead of loading everything into the main conversation. [factory-deferred-context]
[anthropic-best-practices]

Dynamic promotion can damage prompt-cache prefix stability. Codex's agent-loop
write-up says tools and static instructions should remain exact prompt prefixes for
cache hits. A deferred-tool design therefore has two opposing effects to measure:
smaller prompts versus cache misses when the tool set changes. [codex-loop]

## LCA implications

- Treat the system prompt as a tested product surface with a token budget and owner.
- Prefer enforceable harness behavior over prose: syntax checks, sandbox rules, stale
  edit rejection, and deterministic state extraction do not need repeated warnings.
- Keep project instructions short and project-specific; do not copy formatter, linter,
  or generic coding-assistant behavior into every request.
- Load specialized instructions on demand, but keep the small core tool surface stable
  until cache/correctness measurements justify dynamic tool promotion.
- Track which instruction caused a behavior change. Rules without an eval or a known
  incident should decay rather than accumulate forever.
- For newer models, test a materially shorter system prompt rather than merely editing
  individual sentences.

## Experiments

1. **System-prompt ablation:** current LCA prompt versus a minimal core prompt versus
   core + task-selected strategy. Run simple, edit, debugging, and greenfield evals.
2. **Instruction conflict:** inject compatible, redundant, and contradictory project
   rules; measure adherence, latency, and reasoning/tool churn.
3. **Enforcement migration:** remove prose already enforced by tools and confirm the
   same safety/correctness behavior while measuring token savings.
4. **Deferred schemas:** compare all MCP schemas upfront against discovery metadata +
   promotion. Measure total tokens/task, cache reads, tool-selection errors, and task
   success—not prompt size alone.

## Sources

Source IDs resolve through [../sources.json](../sources.json).
