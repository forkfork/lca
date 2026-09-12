# Worker-owned idle suspension

Decision: further validation; enabled for the user's experimental handoff image.
This is a functional calibration, not a general reliability or cost-savings claim.
No remote executor, cloud control plane, new SDK or local AWS credential transfer
was introduced.

The worker checks its queue and durable jobs at completed-turn boundaries. After
300 idle seconds, it acquires the same gate used for atomic input publication,
rechecks activity/queue/jobs, saves the session and requests AWS suspension.
IMDSv2 provides temporary execution-role credentials; the existing curl signs
the request. The role has only `lambda:SuspendMicrovm` on this experiment's image
as its additional permission. AWS authorizes this API at image scope, so this
is not IAM isolation to a single VM. The worker targets its configured VM ID.

The resume lifecycle hook signals the worker to reopen the gate. The client
waits through suspension, resumes before access and reconnects shell ingress.
Pending prompts are saved locally before waking and retain stable IDs on retry.
Passive foreground polling neither refreshes activity nor wakes a sleeping VM;
the client closes shell ingress on suspension intent while keeping the local
terminal available. It waits for AWS's transition before reopening ingress.
The eight-hour hard lifetime and temporary model-token expiry still apply.

## Evidence and failures

Evidence is private under `~/.local/state/lca/experiments/`:

- `20260912-idle-suspend/`: registered probe and functional calibration, frozen
  image 4.0 source, raw terminal/model logs, control-plane state observations,
  independently checked artifacts, usage and termination records.
- `20260912-idle-attached/`: initial attached-terminal failures, raw output,
  collected failed worker and zero-model-call accounting. Evidence retained.
- `20260912-idle-attached-v2/`: the first status-adapter repair still treated
  turn_count as a scalar. Its real-guest failure and fixed-session probe remain
  recorded, with zero model calls.
- `20260912-idle-attached-v3/`: a repeated attached cycle returned an uncertain
  suspension result. Fresh diagnostic worker cycles returned HTTP 200, including
  two cycles on one attached terminal. No root cause was established.
- `20260912-idle-attached-v4/`: fresh no-model validation on image 7.0.

The self-suspend probe succeeded and automatic wake plus shell attachment took
2.46 seconds in that one observation. The main 512 MiB ARM64 AL2027 test proved:

1. A 15-second active command stayed running past a five-second test idle limit.
2. Queued commands finished before automatic detached suspension.
3. CLI wake accepted a real coding turn and later suspended again.
4. A second real model turn succeeded after another resume, exercising provider
   reconnection with existing conversation state.
5. A detached 15-second durable job prevented idle suspension.
6. Return during suspension restored the original checkout/session and terminated
   the VM. The resulting marker files and session ID were independently checked.

The main test used seven model calls, six native tool calls, 53,591 input tokens
(47,872 cached) and 215 output tokens. The repository's frozen standard API
convention estimates $0.115812, excluding priority/subscription billing and AWS.
Seven calls exceeded the registered six-call plan by one: the harness did not
interrupt an in-flight agent turn at that boundary. This is a budget deviation,
not a compliant per-call-budget result. No further paid model trials were run.
Probe, attached-terminal checks and repairs used zero model calls.

Initial probe shell framing and local Lua module-path setup failed before model
work; diagnostics remain recorded. The first passive-foreground attempt stalled
with a closed worker gate while retaining shell ingress. The client was changed
to close ingress and await the AWS transition. An explicit operator suspend
resolved the uncertain request without restarting the worker or replaying work.
The next attachment successfully suspended, then `/status` exposed an existing
headless UI defect: it serialized the session's Lua functions. The corrected
adapter prints explicit scalar status fields and supplies no fabricated optional
callbacks. The initial scalar-field regression missed that turn_count is itself a method;
the final regression uses a real Session, calls its turn_count method, and was
also exercised in the guest before rebuilding. Image 7.0 includes that
fix and better diagnostics for uncertain suspension results; the model/provider
code is unchanged from the successful real-task calibration.

## Boundaries

Twenty-seven Python checks, Lua lifecycle/queue/job gate and status regressions,
and the full existing test suite passed. The idle tests include a prompt racing
suspension and an input preserved across failed wake-up. The microvm source
secret scan found no leaks. Local user defaults are 300 idle seconds and 28,800
seconds maximum lifetime; live checks deliberately used five idle seconds.

The worker gives the terminal a two-second grace period to release ingress.
Uncertain API requests are retried at most three times under the closed gate;
a confirmed resume cancels further retries. This is conservative failure handling,
not proof of why the observed uncertain request failed.
Definitive API refusal before any uncertain request leaves the worker awake. Ambiguous API outcomes keep the
gate closed until a confirmed resume; they are not silently treated as failure
and replayed. Unexpected controller failures still require inspection. An
operator can resolve an uncertain idle request by explicitly suspending/resuming
with AWS after verifying the worker gate and absence of active work; never
remove the gate to force work to start. This slice has no cloud checkpoint store,
expiry rollover or remote model credential refresh. Snapshot operations cost
money, so short frequent pauses are not asserted to save money in every workload.

## Final prepared-image check

Image **7.0** passed the fresh attached-terminal check in
`20260912-idle-attached-v4/`. With the terminal still attached, AWS reported
SUSPENDED. `/status` woke the VM and completed exactly once, then the worker
suspended again. `/local` handled that transition, restored the session and
unchanged fixture, reopened local LCA, and confirmed VM termination. Independent
inspection of the returned worker state and protocol log found one completed
status input and zero model calls. All VMs created for these checks, including
failed and diagnostic fixtures, were confirmed terminated. The prepared default
in the local user configuration is image 7.0, 300-second idle delay and
28,800-second maximum lifetime. Prior failure records remain unchanged; the
passing calibration does not establish long-term reliability or explain the
intermittent earlier API result.
