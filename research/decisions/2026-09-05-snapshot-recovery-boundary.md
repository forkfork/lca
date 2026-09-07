# Conditional snapshot-recovery screen

The user requested another experiment after the ordinary import/body fixture
did not activate recovery. This study targets the known failure boundary rather
than measuring how frequently a model naturally produces it.

## Registration before live calls

Theory `astra_snapshot_boundary_screen`; runner
`evals/snapshot_recovery_screen.py plan-boundary`, followed by the frozen
`screen.py run`. Four serial cells: simple baseline/snapshot controls, then a
seed-927 randomized adjacent coding pair. Model Astra, reasoning high, normal
history, all tools, current identical prompt and schemas; Lua 5.5 and module paths
pinned. Source, engine roots, fixture, grader, driver, theory and runner hashes
are frozen in `evals/results/20260905-snapshot-boundary-screen/manifest.json`.

The engine intervention is unchanged from the preceding screen: the bounded
eval-only snapshot-recovery wrapper, with no production behavior change.
A common frozen driver adds the same deterministic history in both arms:
read saved Snake source, read the task tests, execute the literal captured import
edit, then execute an edit with captured coordinates 63–125 and old tags JPJA/lNQO.
Native call/result IDs are preserved. Sorted argument serialization makes the
history identical through the final call; only its actual result differs.
Baseline must reject it as stale; treatment must report snapshot recovery.

The original log truncated the generated body, so the replacement is explicitly
reconstructed: add `wave_offset(phase) = round(3 * math.sin(phase))` ahead of the
unchanged original draw/play source range. It is not the original visual-feature
task. Public and hidden behavior checks, preserved existing AST and protected
files, and completed post-mutation test evidence determine success independently
of model claims. No UI smoke is needed for this helper-only task.

Two offline seed tests require exact file bytes, correct baseline/treatment
activation, and closure of all four native call/result pairs both in session
history and the provider's actual serialized request. Grader controls accept a
known-good artifact and reject incorrect output, changed amplitude, changed game
constants, missing verification and modified protected files. The earlier nine
snapshot safety tests remain required. The full Python preflight runs before
any paid calls. Raw seed events/history and every live request/response are saved
outside task workspaces.

Budget: maximum four runs, 360 active seconds, 150 seconds per cell and a $1.50
between-cell standard-equivalent estimated-cost threshold (one-cell overshoot
possible). Stop on task, protocol, activation or request-audit failure, unknown
usage, or exhausted budget. There are no retries. Every outgoing request audits
model, effort and normalized prompt/tool parity; the first coding request must
retain the entire seeded history. Audits require identical cross-arm history
before the differing final tool result.

Advance only if all cells pass, treatment saves at least one live model request,
coding continuation time falls at least 10%, and output tokens increase no more
than 10%. Include fixed seed execution time; exclude historical model generation
identically from both arms. Excluded historical generation is not claimed to have
zero cost. A positive result supports fresh conditional validation only: it does
not establish ordinary end-to-end speed, failure prevalence, or default promotion.

## Completed: recovery works, round-trip gate missed

All four cells passed. Native seed activation, exact prefix equality, first-request
history retention, and every model/effort/prompt/tool audit passed. Coding baseline
received the stale failure; treatment recovered once. There were no live provider
retries or missing usage. The seeded failure is recorded in boundary.json/events;
the generic transcript-derived stale-tag metric does not count pre-model seeds.

| Task | Arm | Time | Live model calls | Output tokens | Estimated cost |
| --- | --- | ---: | ---: | ---: | ---: |
| Simple | Baseline | 2.330 s | 1 | 5 | $0.040922 |
| Simple | Snapshot | 2.552 s | 1 | 5 | $0.040892 |
| Recovery | Baseline | 16.281 s | 3 | 258 | $0.236852 |
| Recovery | Snapshot | 14.318 s | 3 | 160 | $0.126562 |

Time fell 12.1%, output tokens 38.0%, and estimated cost 46.6%. Cache reuse also
differed substantially, so the cost delta is not attributable solely to recovery.
Total estimated cost $0.445228; active runner time 35.763 seconds. All estimates
are standard API equivalents, not exact service-tier billing.

Both arms still used three live calls. Treatment first read README, then ran tests,
then answered. Baseline batched the README read with its short repair, then tested
and answered. The model did not regenerate the original entire source block; it
inserted just the missing helper. Treatment's test command also attempted a Git
diff in this non-Git fixture; the completed successful tests precede that unrelated
failure, which the frozen grader accepts symmetrically.

Decision: fail the predeclared model-round gate; no default change or speed claim
for normal tasks. The tool-level recovery mechanism activated, but spare model
rounds were absorbed by remaining inspection. Preserve all original evidence.

## Fresh fully inspected boundary registration

The next small screen changes the common starting population: README is also read
before the fixed import/body calls. Both arms receive that extra actual native
read identically. This asks about a fully inspected task at the recovery boundary;
it is not a repair or regrade of the previous experiment. The old cells are not
pooled with the new controls.

Theory `astra_snapshot_inspected_boundary_screen`; selector `plan-inspected-boundary`.
Seed 928, four fresh serial runs, same Astra/high, prompt, schema and prototype.
Same 360-second active budget, 150-second cell deadline, $1.50 between-cell estimated
threshold and stop/advance gates. Five native prefix pairs must close, README read
must be present, baseline must reject and treatment must recover. Four offline
boundary checks now cover both arms with and without the prior README inspection.
No other fixture, grader or tool behavior changes. Freeze new evidence under
`evals/results/20260905-snapshot-inspected-boundary-screen/` before launching.

## Fully inspected screen completed: advance conditional validation

All four fresh cells passed. The seeded README read was present in both coding
arms, all five native call/result pairs survived provider serialization, and the
complete common history through the final call matched. Baseline rejected the
mixed tags; treatment recovered once. All outgoing model/effort/prompt/schema
audits and frozen-engine hash checks passed. No provider retries or missing usage.

| Task | Arm | Time | Live model calls | Output tokens | Estimated cost |
| --- | --- | ---: | ---: | ---: | ---: |
| Simple | Baseline | 2.581 s | 1 | 5 | $0.040912 |
| Simple | Snapshot | 3.539 s | 1 | 5 | $0.040932 |
| Fully inspected recovery | Baseline | 15.146 s | 3 | 204 | $0.127876 |
| Fully inspected recovery | Snapshot | 8.706 s | 2 | 93 | $0.093786 |

Treatment eliminated the live repair call: baseline repaired, tested, answered;
treatment tested and answered. Coding continuation time fell 42.5%, output tokens
54.4%, and estimated cost 26.7%. This meets the predeclared gates. The simple
negative controls both used one model call and no tools; their latency differed
despite the recovery tool never executing, illustrating endpoint variation.

Decision: advance to fresh held-out conditional validation, keeping the prototype
experimental. One coding pair cannot establish a reliable effect size, failure
frequency, or a population-wide speedup. The previous partial-inspection screen
still failed its model-round gate; it is not pooled with this favorable result.
Validation should use other files/ranges and independently changed source as a
negative control, before considering a normal runtime change.

The second screen cost $0.303506 estimated and took 30.256 active runner seconds.
Both new screens together cost $0.748734; including the prior ordinary-task
screen, the three live screens total $1.069812 standard-equivalent estimated cost.
No failed or unknown-usage model attempts are omitted. Fixed replay calls are
recorded separately from live model generation, whose historical cost was excluded
identically rather than assumed to be zero.

Validation this turn: four offline boundary activation/native-pair/exact-byte
checks, the nine adversarial snapshot checks, known-good/bad grader checks, and
the full 111-test Python eval suite passed. `make local` completed after changes.
Only eval machinery, fixtures, tests and this decision record changed; the normal
tool registry does not install snapshot recovery.
