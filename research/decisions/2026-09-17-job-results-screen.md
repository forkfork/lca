# Job lifecycle hardening and compact-result screen

Decision: **further validation**, not a general efficiency adoption claim and not
approval to add completion notifications. The final registered screen passed all
correctness, activation and advance gates. Existing user-authorized lifecycle and
response-interface changes remain in the checkout.

## Correctness changes

Jobs record Linux boot and process start identifiers. Group signalling rejects
mismatched identities and live legacy jobs without identity metadata. Group
liveness includes surviving descendants when the original leader is gone, so a
lost supervisor does not hide an orphaned command tree. Regression tests verify
that an unrelated process is left alive after a stale-PID stop attempt and that
an orphaned group remains visible and stoppable. The checks reduce stale-PID risk;
check-then-signal is not an atomic ownership boundary like a cgroup.

The earlier process-tree test checked immediately after SIGKILL, before the
scheduler necessarily completed termination. It now checks eventual termination
within a bounded interval. One focused run segfaulted while a local native-module
reinstall overlapped it. Reinstall overlap is a plausible explanation, not a
proven root cause. Three consecutive isolated job suites and subsequent full
suites passed. Do not reinstall native modules alongside running tests.

Validation: focused job/lifecycle/formatter suites; `make local`; full `make test`
including Python eval tests; `git diff --check`. The final archived workspaces
also passed independent regrading with the frozen grader, without replacing the
original grades.

## Registered comparison

Observation: `/tmp/lca/logs/lca-20260916-191522-707162.log` and its JSONL, calls
26:5, 26:7, 26:8 and 26:10, repeated an approximately 9.7 KB command in wait results.

Final registration: `evals/theories/job_results_screen_v4.json`. Both arms use
GPT-6 Astra, high reasoning, the same prompt/tool schemas and hardened runner,
and the same wait deadlines. Only model-facing command rendering differs:
`full_command` restores the full command through an eval-only formatter wrapper;
`compact` uses the bounded production formatter. A deterministic wrapper adds
the same non-executable padding to verification-job metadata in both arms. The
model is not asked to generate or count repetitive padding. This isolates the
response mechanism but is a synthetic task, not a natural long-running workload.

Four cells, seed 917, one run per arm on `simple_prompt` and `job_receipt`.
Independent grading checks aggregation correctness, protected verifier scope,
a receipt matching the final source hash, a successful durable verification job,
and actual observation of terminal status, exit code and output. Activation is
checked against actual serialized provider requests. Source freezing includes C
sources as well as Lua, Python, fixtures, graders and registered configuration.

## Final screen results

All four cells passed original grading and activation. Separate regrades of all
four archived workspaces passed as well.

| Task / arm | Time ms | Model calls | Tool calls | Prompt tokens | Output tokens | Cached tokens | Job-result bytes | Estimated cost USD |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Simple / full command | 2,209 | 1 | 0 | 3,115 | 5 | 0 | 0 | 0.031400 |
| Simple / compact | 2,613 | 1 | 0 | 3,121 | 5 | 0 | 0 | 0.031460 |
| Coding / full command | 16,834 | 5 | 4 | 20,012 | 218 | 9,600 | 19,411 | 0.124620 |
| Coding / compact | 13,455 | 5 | 4 | 17,370 | 202 | 13,056 | 791 | 0.066296 |

Coding paired differences: 95.92% fewer job-result bytes, 20.07% lower elapsed
time, 13.20% fewer prompt tokens, unchanged model/tool calls, and 46.80% lower
estimated cost. Cache usage differed, so the cost difference must not be treated
as a stable price reduction. The simple task was 404 ms slower with compact
results even though neither arm used job tools; one sample cannot resolve timing
noise. Simple-task spending is included but its time is excluded from the
registered coding-speed gate.

These values meet the registered advance rule: all cells correct and activated,
at least 80% less job-result text, neither coding time nor cost more than 10%
worse, and no increase in coding model calls. This supports fresh validation,
not statistical significance, broader task claims, or promotion from a screen.
It does not test cursor ergonomics, wait duration, or completion notifications.

## Invalid attempts and accounting

No historical cell was retried or overwritten. Each fixture repair received a
fresh registration and source snapshot before live execution.

| Registration | Outcome | Active worker seconds | Estimated cost USD |
|---|---|---:|---:|
| v1 | Launcher selected Lua 5.4; failed before any model request | 0.064 | 0 |
| v2 | Two simple controls passed; coding artifact correct, activation failed on exact padding count | 38.042 | 0.219818 |
| v3 | Two simple controls and all coding artifact gates passed; agent shortened padding, so large-command activation failed | 23.222 | 0.154448 |
| v4 | All four cells passed; valid paired comparison | 35.555 | 0.253776 |

Total: 11 attempted cells, 10 model-bearing runs, approximately 96.88 active
worker seconds and **USD 0.628042 standard-API-equivalent estimated cost**,
including invalid runs. Values use the frozen runner's price table; they exclude
service-tier/hosted-tool surcharges and are not a Codex subscription bill.
Preflight, compilation, local tests and analysis time are outside active worker
time. The launcher now selects the project's required Lua 5.5.

## Evidence and next gate

Durable evidence is under
`/home/tim/.local/state/lca/research/job-results-screen-20260917-v1` through `-v4`.
Each contains the immutable manifest and frozen source; campaign copies preserve
requests, responses, raw traces, workspaces and original grades. V4 also contains
`metrics.json` and separately named `cell-*-independent-regrade.json` reports.
Original campaigns remain under `evals/results/` outside each evaluated workspace.
The source-log observations are preserved with v1. The v4 source SHA256 is
`f385dd11b03c2953a9d312cc9f2d3346ae563a1cbdf703b1d7e533d461f2609e`.

Next: pre-register fresh task validation with meaningful failures, separate
stdout/stderr, large output and independent work while a dependency runs. Require
artifact correctness and terminal evidence alongside time/cost. Do not add
notification architecture based on this formatter-only screen.
