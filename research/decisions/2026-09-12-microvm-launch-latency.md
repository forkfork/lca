# Prepared-image launch latency: further validation

Three serial launches in Sydney from the prepared AL2027 LCA image reached a
working AWS shell in 2.338, 2.209 and 2.156 seconds (median 2.209 seconds).
Loading `agent.core` and `agent.crypto` completed at 2.400, 2.279 and 2.222
seconds respectively. Raw PTY output independently confirms both execution
markers in all three runs. No model calls or credentials were involved.

The clock starts before the local AWS CLI `run-microvm` subprocess and includes
CLI overhead, shell-token retrieval, WebSocket connection and command execution.
Run API responses arrived at 0.526, 0.563 and 0.487 seconds. Image building,
workspace/session transfer, credential provisioning and model latency are
excluded. This measures local-terminal-to-working-shell latency, not isolated
AWS boot time or complete session migration.

The baseline was image `lca-launch-20260912`, version 1.0, ARM64, 1024 MiB,
in `ap-southeast-2`, with AWS shell ingress and public internet egress. Its
artifact SHA256 was
`341b6b15146c14f2795f0872fda987bc8b6b57db68b22bdbad9f8a9842bac801`.
The registered calibration and frozen scripts, image configuration, timings,
raw output and cleanup records are retained outside the checkout at
`/home/tim/.local/state/lca/experiments/20260912-launch-latency/`.
The final three samples are in `token-retry/`.

Four earlier attempts remain in the evidence: two timing-client failures
waiting for an incorrectly newline-delimited secondary marker (60 seconds
each); one fully successful launch (shell 2.236 seconds, modules 2.335 seconds);
and one shell-token API failure at 2.413 seconds whose service error was not
captured. The later script records service errors and allows bounded token
retries, included in elapsed time; none occurred in the final three samples.
The first script also mishandled the empty successful termination response.
These failures limit reliability conclusions and are not silently included as
successful latency samples. All seven VMs were confirmed TERMINATED.

Model calls and tokens: zero across every attempt. AWS image-build, storage
and VM charges were not measured. All VMs used a 120-second maximum lifetime
and explicit termination; the temporary image, artifact bucket and IAM roles
were scheduled for deletion or deleted after measurement.

Decision: further validation. Approximately 2–3 seconds is supported for this
prepared-image launch path in these samples. This tiny calibration establishes
neither a latency SLA nor handoff correctness. No handoff implementation or
LCA runtime changes were made for this measurement.
