# Whole-agent MicroVM feasibility screen — 2026-09-12

Registered before model calls or infrastructure creation. This is a deployment
compatibility screen requested by the user, not a change to agent reasoning or
an adoption/performance experiment. There is no antecedent bad river/log turn:
the observation is the repository's real Lua 5.5/native dependency contract.
`evals/EXPERIMENTS.md` was read before designing this screen.

- Mechanism: package the entire unmodified agent and workspace into one Linux
  application container; let Lambda snapshot an idle readiness process; start
  LCA through AWS shell ingress after restore. All tool execution remains local.
- Control/treatment: the same ARM64 AL2027 Dockerfile in local Docker (QEMU on
  this x86 host), then a Sydney Lambda MicroVM. Platform placement is the changed
  factor. Local-first ordering is required by the user; it is not randomized.
- Two cases per environment: read README/run Git without edits, then repair the
  small Lua clamp fixture and run tests. Exact prompts and grading are in
  `smoke.sh`; model `gpt-6-astra`, reasoning `medium`, tier `priority`.
- Pinning: `package.py` creates a SHA256 map of the actual working tree sources
  (including pre-existing edits), fixture, Dockerfile, bootstrap and grader.
  Preserve this manifest and artifact before running. No prompt/core changes.
- Validity: test the artifact grader against the broken fixture and a known-good
  repair; verify Lua/native modules, CA paths, shell, Git, ripgrep, PTY and
  readiness locally. Preserve serialized model requests/responses and tool events
  using the existing LCA recorder, activated only for the batch agent process.
- Budget: four live agent invocations, 240 seconds each plus 10-second shutdown
  grace; stop on invalid activation or failed case. One MicroVM, 1 GiB baseline,
  maximum lifetime 3600 seconds; at most two image attempts before reviewing the
  concrete failure. OAuth usage is reported in tokens; monetary API cost is not
  available from the subscription transport and must not be invented.
- Primary gate: successful AWS image/version snapshot, actual shell ingress,
  successful model loop, reads, commands, edit, Git diff, unchanged fixture tests,
  independent exhaustive output checks. Grade independently of final prose.
- Secondary evidence: module/shared-library versions, OS/kernel/architecture,
  outgoing model/reasoning activation, raw AWS errors, calls, usage, elapsed time.
  QEMU timings cannot establish native performance.
- AL2027 preference: install its own `openssl-snapsafe-libs`; do not disable
  SELinux or add capabilities. Only introduce AL2023 if an observed blocker
  warrants a control; do not label a generic build/network error an OS failure.
- Decision: a pass justifies further validation of the deployment primitive;
  it does not adopt a control plane or establish long-task reliability. Record
  results and limitations under `research/decisions/`.

Evidence during execution: `/tmp/lca-microvm-evidence-20260912`, copied to
`~/.local/state/lca/experiments/20260912-microvm` at completion. Credentials are
kept separately in a temporary file, never in the artifact/evidence or snapshot.

## Revision 2 registration (before further model calls)

The original screen stopped after local-simple/local-coding passed and
microvm-simple failed on its second model request. Preserve all three cells;
microvm-coding was not run. The first request/tool batch succeeded, then empty
arrays became invalid JSON. Native offline reproduction and upstream C source
identify lua-cjson's 47-bit masked lightuserdata compared against an unmasked
pointer. The same `.so` under QEMU did not reproduce the high-address layout.

Intervention: use cjson's existing empty-array metatable in LCA's response replay
normalization. No AWS conditional. A new regression failed before the fix;
the provider suite passes both locally and on the actual VM, and `make check`
passes. Original failed wire records stay untouched, including two malformed
JSONL records. The error belongs to dependency serialization, not snapshots.

Freeze `context-v3` with the corrected source. Run a fresh four-cell screen with
the same prompts/model/fixtures/time limits, in new local workspaces and a
replacement VM from the rebuilt image version. No concurrent extra VM; terminate
the diagnostic VM first. This is the second image build attempt. This amendment
authorizes four additional agent invocations, not retries of original evidence.
Keep original and repaired results distinct; report unknown final usage for
the rejected requests rather than treating them as free.
