# Follow-ups after the frozen Astra speed campaigns

Do not modify experiment source while the current campaigns are running.

## Local tools without hosted browsing

Inspection of `lua/agent/providers/codex.lua` shows that ordinary tool-enabled
requests always append hosted `web_search`, even for self-contained local coding.
The interrupted prompt pilot's first response attributes 5,213 input tokens to
tools versus 1,750 to instructions. That is total tool attribution, not proof of
how much belongs to hosted browsing. Measure the difference; do not assume it.

A small next intervention could expose `local_only`: preserve every native tool
and remove only hosted web search from the provider payload. Compare against
normal tools with identical prompt/model/effort on explicitly offline tasks.
Provider payload tests and live token attribution must establish activation.
Keep default browsing capability for tasks that need current external evidence.
Primary outcome remains correct solution latency, not schema token reduction.
Implemented and under test in `astra_local_tools_speed` (seed 914). Provider
payloads and actual tool-token attribution are captured. See the separate
local-tools decision record; do not infer a result before the campaign completes.

## Planner removal

Current normal planning is already once-only and can be batched with other tools.
Removing it may save schema/output tokens without saving a model round trip.
An honest no-planner treatment must hide the native tool and remove its prompt
requirements together, while preserving safety, task scope and verification.
Measure actual planner use in controls before funding a larger comparison.

## A longer current-model workload before planner claims

Historical auth_api runs include 20+ tools and actual repair sequences, unlike
the bounded edit cohort. They used older harnesses with repeated plan updates,
so their three-to-five planner calls do not establish current Astra overhead.
First calibrate the current normal harness on this build task; keep all tool
usage, failures and latency rather than selecting only slow runs afterward.

The existing auth grader permits a passing score with some behavioral checks
false and merely searches executed command strings for the word `test`. Before
using this task for a speed decision, introduce a separately versioned strict
contract requiring every specified behavioral check, successful final test
evidence, protected README, and no unrelated infrastructure. Test it against
known-good artifacts and independently corrupted security/functional artifacts.
Keep original historical grades untouched. A single API build family still does
not supply the requested 20–50 diverse long coding tasks.

## Expose observed Git work-tree state

The local-tools pilot's all-tools cell-0008 attempted `git diff --check` before
its test command in a non-Git workspace. The command chain stopped before tests,
and the next model response regenerated verification. This is a concrete
environment-assumption failure, not missing coding skill. The project index
already calls `git rev-parse --is-inside-work-tree` to select its inventory
strategy, but does not expose that result in the model-facing environment.

Candidate: surface the observed Git state as a fact, not another generic workflow
instruction. Distinguish inside-work-tree, outside-work-tree and unavailable or
failed probe. Preserve ordinary Git use in real repositories. Test on non-Git
tasks and a real Git work-tree control; do not infer a general speedup from this
one avoidable failure. Register the intervention after the live source freeze.

## Exact edits

The legacy exact-edit executor remains, but `driver.lua`'s historical exact prompt
transform expects old textual tool-call markup absent from the current native
prompt. Do not run that historical switch as though it were a valid Astra
treatment. A new native schema and positive/negative activation checks are needed.

## Command replay by reference: not justified by current traces

Read-only screening across the completed reasoning screen, reasoning validation
and local-tools campaign found zero exact repeated `run` command strings of at
least 200 characters within a trajectory. Long verification scripts sometimes
get regenerated with changes, but an exact replay handle would not avoid that
generation. Do not add a command-replay schema/retention mechanism on the basis
of these workloads; reassess on genuinely long traces if repeated large commands
become a measured cost. This is a local trace result, not a universal rejection.
