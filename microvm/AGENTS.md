# MicroVM maintenance lessons

- Verify lifecycle outcomes with AWS `GetMicrovm`, using bounded polling.
  A worker's `suspending` phase, terminal message, or successful API response
  does not prove that AWS has reached `SUSPENDED`. Avoid fixed-delay assertions.
- On suspension intent, release shell ingress and wait for the AWS transition
  before reconnecting. Passive `fg` polling must not refresh activity or wake
  the VM. Test repeated sleep/wake cycles with the local terminal left open.
- Determine idle state from active turns, queued input and tracked durable jobs,
  not CPU usage. Keep input publication and suspension under the same gate.
  Persist prompts before attempting wake-up. An uncertain suspend result must
  not trigger gate deletion or work replay; use the confirmed resume hook and
  inspect unresolved failures.
- Exercise headless commands with real `agent.session` objects and the real
  dispatcher before building an image. `/status` failed twice because a generic
  encoder encountered functions and a stub concealed that `turn_count` is a
  method. Run no-model command checks before paid coding turns.
- Preflight packaging before an AWS build: check the artifact allowlist, runtime
  files copied before `luarocks make`, lifecycle hooks, and the installed launcher
  from outside the checkout with its LuaRocks environment. Run relevant local
  tests, then freeze and hash the artifact. Host-only fixes do not require an
  unchanged guest image to be rebuilt.
- Treat image retention as part of preparing a replacement: after validation,
  inventory old versions and identify cleanup candidates. Retain the configured
  default, one validated rollback, and every version referenced by a nonterminated
  VM in AWS (including suspended VMs). Scope cleanup to LCA-owned images; never
  infer ownership from a name alone. Do not put account cleanup on the `fg` path.
- Keep live checks short and explicitly budgeted; enforce model-call limits
  before starting another call. Preserve failed trials separately from repairs,
  verify test VMs reach `TERMINATED`, and restore normal defaults after testing.
  Do not turn an unexplained transient failure into a claimed AWS limitation.

See [HANDOFF.md](HANDOFF.md) for operation and
[the idle-suspend decision](../research/decisions/2026-09-12-idle-suspend.md)
for the supporting successes, failures and remaining limits. Follow the root
experiment instructions before running further hypothesis experiments.
