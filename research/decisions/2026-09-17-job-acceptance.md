# Durable job acceptance and fresh-task screen

Decision: the deterministic acceptance and clean-install gates pass for the
user-authorized job changes. Reject the hypothesis that compact results meet the
registered fresh-task efficiency gate: estimated cost regressed beyond tolerance.
Do not promote a performance claim from this screen or add notification machinery.
The bounded command display remains part of the explicitly requested interface
work; it is not being adopted as a proven speed/cost optimization. Both arms used
the same hardened lifecycle, cursors and waits, so their relative efficiency was
not tested by this comparison.

## Acceptance work and fixes

`tests/test_job_acceptance.lua` exercises discovery, waiting, reading and stopping
from a new process after the launcher exits; concurrent jobs with distinct exit
codes; byte-for-byte reconstruction of both stdout and stderr through 997-byte
cursor reads (over 220 KB per job); and legacy jobs that lack process identity.
The existing lifecycle tests cover startup/stop races, supervisor loss, surviving
children, process-group escalation and stale identity rejection.

A refused legacy stop now says why it cannot safely signal and gives the PID
inspection command and replacement-job recovery path. Its tool summary now says
`stop failed`, rather than incorrectly reporting an unknown job.

A clean install exposed that `lca --help` exited 2. Explicit help now prints to
stdout and exits 0; invalid subcommands still fail. Regression coverage checks both.
The isolated suite also exposed a cache-prefix test launching system Lua 5.4
against Lua 5.5 modules; it now selects the required Lua 5.5 runtime.

`scripts/check-clean-install.py` snapshots the checkout, builds into a new isolated
LuaRocks tree, verifies application and native-module origins outside the source
checkout, runs the installed CLI, and runs the full suite. The selected LuaRocks
tool's loader path is included separately; its configuration exposes only the
isolated dependency tree. No existing application installation is needed to pass
the module-origin gate.

Validation: focused acceptance and CLI suites; grader/audit positive and negative
tests; cache-prefix tests with the LuaRocks environment; `make local`; full
`make test`; isolated install and full suite; `git diff --check`.

Reproduce the clean check (choose a new output directory each time):

```sh
python3 scripts/check-clean-install.py /tmp/lca-clean-acceptance \
  --luarocks /home/tim/.local/luarocks-3.13/bin/luarocks
```

Retained clean-install evidence lives under
`/home/tim/.local/state/lca/research/job-acceptance-clean-20260917-v1` through `-v5`.
V1 failed due to LuaRocks option placement, v2 selected an incompatible system
LuaRocks, v3 found the CLI help bug, and v4 first lacked the LuaRocks tool loader;
a separately logged v4 rerun then exposed the Lua-version test bug. V5 passes all
four stages. A direct focused Python invocation without the project's LuaRocks
environment also failed; the configured invocation passed. These are local
build/harness attempts, with no model spend.

## Frozen fresh-task comparison

Registration: `evals/theories/job_results_fresh_screen.json`, seed 918, six cells,
GPT-6 Astra/high. Same execution, schemas, prompts and tasks in both arms; only
command rendering differs. Commands have real options longer than 160 characters,
with no synthetic padding. Tasks require observing a failed build before fixing
it, and starting two jobs before making an independent edit and releasing them.
Independent grades check final artifacts, protected verifier scope, receipts of
the final source hash, observed terminal status/output, and no abandoned jobs.
Actual serialized provider requests pass formatter activation checks.

All six original grades and six separately saved frozen-grader regrades pass.

| Task / arm | Time ms | Model calls | Tool calls | Prompt tokens | Output tokens | Cached tokens | Job-result bytes | Estimated USD |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| simple_prompt / compact | 4122 | 1 | 0 | 3117 | 5 | 0 | 0 | 0.031420 |
| simple_prompt / full_command | 3576 | 1 | 0 | 3118 | 5 | 0 | 0 | 0.031430 |
| job_failure_recovery / compact | 27283 | 7 | 6 | 26874 | 355 | 13952 | 1719 | 0.160922 |
| job_failure_recovery / full_command | 24647 | 7 | 6 | 26972 | 348 | 18048 | 1879 | 0.124688 |
| job_overlap_edit / full_command | 20626 | 5 | 8 | 20588 | 576 | 15104 | 1942 | 0.098744 |
| job_overlap_edit / compact | 19048 | 5 | 7 | 20544 | 548 | 11008 | 1790 | 0.133768 |

Compact vs full-command paired differences:

- Failure recovery: time +10.70%, estimated cost +29.06%; calls unchanged.
- Overlapping jobs: time -7.65%, estimated cost +35.47%; one fewer tool call,
  same model calls.
- Coding total: time +2.34%, estimated cost +31.89%. Both the aggregate 20%
  cost tolerance and the per-task 35% cost tolerance fail.

Coding job-result bytes fell from 3,821 to 3,509 (8.17%). Prompt tokens declined
slightly, while cache reuse was lower in both compact coding cells. A single pair
cannot attribute the cost increase to rendering or establish stable performance;
it still fails the predeclared gate. No reruns were launched to chase a better
result. This fresh result supersedes any inference of general savings from the
previous padded-fixture screen.

Total fresh screen: USD 0.580972 standard-API-equivalent estimate and 99.937 active
worker seconds, including controls. Combined with prior retained attempts:
USD 1.209014. Estimates exclude service-tier/hosted-tool charges and are not a
subscription bill. Local builds, tests and analysis are outside worker time.

## Evidence and limits

Frozen source, manifest, complete campaign (requests, responses, original grades,
traces and workspaces), metrics and separately named independent regrades are at
`/home/tim/.local/state/lca/research/job-results-fresh-20260917-v1`.
Frozen source SHA256:
`4a68f75e77b64430abea21061b3a846ef6b917e0c8658d0914abcb69b2ffdb20`.
The clean-install loader-path and test-runtime fixes were made after the frozen
screen completed; neither was changed between live cells.

These checks establish the exercised restart, output and lifecycle behavior;
they do not simulate power loss or establish long-task performance. PID identity
checks still have a check-then-signal window and are not atomic cgroup ownership.
There is no new review or approval gate. Any future efficiency claim needs a new
registered comparison, rather than counting this failed cost gate as success.
