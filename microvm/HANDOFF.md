# Experimental session handoff

This is an opt-in vertical slice. LCA runs normally on one machine at a time;
commands are not individually forwarded. The local terminal can detach and
reattach to a single headless agent inside a prepared MicroVM.

## Configure

The first `/cloud` or `/bg` prepares a reusable image automatically. It selects Sydney by
default (or `AWS_REGION` / `AWS_DEFAULT_REGION`), creates the build and execution
roles and private backup storage, uploads only packaged LCA source, and waits for
AWS to build and snapshot the image. The terminal explains that this first build
can take several minutes. Later handoffs reuse the saved image without rebuilding.

You need working AWS credentials with permission to create/pass IAM roles,
configure the S3 bucket, and build/run Lambda MicroVMs. LCA does not install the
AWS CLI or obtain AWS credentials. Local-only use performs no AWS setup.
Configuration is saved privately at `~/.config/lca/microvm.json`; no configuration
file is required initially. Optional overrides can be supplied there beforehand:

```json
{
  "aws_cli": "/path/to/current/aws",
  "region": "ap-southeast-2",
  "maximum_duration": 28800,
  "idle_suspend_seconds": 300
}
```

A configured `image_arn`, `image_version`, and `execution_role_arn` keep the manual
prepared-image workflow. Automatic builds use a local setup lock and persist their
request token and pending image before waiting. An interrupted wait is resumed on
the next `/bg`; an uncertain create response is retried with the same token.
Setup errors restore the local checkpoint before reporting failure. Builds that
AWS marks failed retain diagnostics and require investigation, rather than
creating replacement images in a loop. A 30-minute wait timeout leaves the build
available for the next attempt. Upgrading local LCA does not automatically rebuild
an already configured image.

The host needs Python 3.12+, `websockets` 15+, Git and the current AWS CLI.
The MicroVM needs only the existing Lua environment. `make local` installs the
client alongside LCA; no command environment variable is needed:

```bash
lca
```

Start at your project root. Queue follow-up prompts
while LCA works, then type `/cloud` to move and stay attached, or `/bg`
(`/background`) to move and detach. Both take precedence over
queued input, waits for the current turn to finish, and transfers the remaining
queue. Active durable background jobs must be finished or stopped first.
For a new project, `/bg` initializes Git and creates an empty initial commit
automatically. An existing repository without commits also gets an empty initial
commit, preserving staged files. Existing history is unchanged. Nonignored
untracked project files are included in the transfer. Inside an existing Git
repository, start LCA at its root. A failed preflight leaves LCA local.

```bash
lca fg                  # attach; prompts and /test can be submitted
# /detach or Ctrl-D detaches the terminal; the worker keeps running
# /local waits for the active turn, merges home, terminates the VM, reopens LCA
lca local               # same return operation directly from your shell

# Optional manual export workflow:
lca collect ../returned # stop after active turn; export workspace and remaining queue
lca stop                # terminate the VM after collection
```

`!command` runs a shell command in the session's working directory, locally or
inside the MicroVM according to current ownership. For example, `!ls`, `!git diff`
and `!pwd` require no model call. Commands wait behind the current turn and earlier
queued input. Output and exit status are retained in conversation history; `/test`
is unchanged. The display/history contains bounded stdout/stderr tails, with paths
to the full job logs. Each command gets a fresh shell, so `!cd subdir` does not
change the next command's directory; use `!cd subdir && command` instead.
Older running VMs must be brought home with `/local` and backgrounded again using
an updated prepared image before they can accept `!command`.

`fg` uses the local animated TUI when attached to an interactive terminal.
Animation and input editing run locally; the agent and tools still run in the VM.
A persistent orange remote badge above the input identifies the remote session and shows
connecting, ready, working, sleeping, waking or reconnecting status.
Use `/effect drift` (or another local effect) to change the animation.
`LCA_REMOTE_PLAIN=1 lca fg` retains the plain terminal view, also used for pipes.
The current display follows worker running/idle/sleeping state and completed
session snapshots; it does not yet stream model tokens or show individual tool animations.
Reattachment restores the last three conversation turns, including work done
locally before handoff, using the normal framed replies and river artwork for
turns with tool calls. Restored tool counts come from session history; historical
timings are not reconstructed. Repeated polling does not duplicate those turns.
Remote slash-command output remains visible separately. The plain view still
shows the accumulated worker log.
Ctrl-C, Ctrl-D or `/bg` detaches; it does not cancel remote work. `/cloud`
while already remote keeps the current attachment and does not create another VM.
Initial queued input executes in order; later submissions have
stable IDs and a local outbox so reconnect can resend the same item safely.
Supported remote slash commands: `/test`, `/status`, `/context`, `/reasoning`,
`/service-tier`. The animated client rejects other slash commands locally.
The plain client still forwards unsupported commands, which fail the worker.
`/detach` and `/local` are handled by the local client.

## State and ownership

The checkpoint contains the existing session ID, messages/tool results, plan,
compaction and operational memory, settings, and pending input. The worker
regenerates its system prompt for the new machine. Historical text retains its
original paths; the current working directory is relocated. Current project
AGENTS/CLAUDE instructions are read normally. No new summary is generated to
perform the transfer.

Local state is fenced before remote execution is authorized. A failed transfer
leaves `.lca-handoff.json` in the original project; the same session cannot run
there. `lca recover` is allowed only before remote ownership was committed, and
terminates any known VM before restoring the local checkpoint and queue. If the
launch outcome is unknown, recovery fails closed pending AWS reconciliation.
After ownership commitment, collect the remote state instead of replaying local
work. A worker crash records the active item and does not automatically restart
it; arbitrary tool effects are not claimed to be exactly-once across crashes.

`/local` first stops the worker at a completed-turn boundary and downloads an
isolated copy. It three-way merges working files and Git staging independently
against the original snapshot. Nonoverlapping local edits survive. The same
session, plan, memory and remaining input queue return to the original checkout;
LCA reopens automatically after AWS confirms VM termination.

Conflicting file changes pause before any working-file/index writes. The error
names the files and the downloaded remote copy; resolve local edits, then retry
`lca local`. Changing Git HEAD on either side requires explicit commit
reconciliation in this first slice. A failed worker is never replayed silently.
Keep editors and Git operations idle during the final application step. A saved
return transaction permits retry after partial application; an index lock left
by a killed process needs manual inspection before removal. This is not a
filesystem-wide atomic transaction. Original and returned snapshots are retained
privately for recovery. `lca collect` remains available as a manual export into
a new directory, without applying changes to the original checkout.

## Project and credential boundaries

The bundle contains current HEAD history, staged changes, unstaged changes,
untracked nonignored files, executable bits and internal symlinks. Staging and
working files remain separate. Git configuration, hooks and source remote URLs
are not copied. Worktree Git metadata is normalized into a standalone repository.
Snapshots fail if Git or selected files change while they are being captured.
Ignored files and machine-local dependencies are not transferred. Submodules,
unmerged indexes, external symlinks and special files are rejected in this slice.
The default transfer limit is 100 MiB for file contents and 100 MiB for Git history.

Known credential filenames and private-key headers are rejected, but this is not
a comprehensive secret scanner. Project contents, Git history and conversation
may contain sensitive data; only use this experiment with projects authorized
for AWS. Credentials are transferred separately through authenticated shell
ingress after echo/history are disabled. Only the current Codex access token,
account ID and expiry move; no refresh token, ~/.aws or ~/.ssh is copied.
Access-token refresh is not implemented. Checkpoints and local ownership files
are private (0600); temporary state directories use 0700.

The default lifetime is **8 hours (28,800 seconds)**, including idle or suspended
time. AWS currently accepts at most 8 hours, so 24 hours is rejected explicitly.
See [AWS launch limits](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html).
The client shows remaining lifetime when backgrounding, attaching and detaching.
This is a hard expiry, not an idle timeout: return before expiry to retain remote
work. There is no automatic export or rollover at expiry. Temporary model access
tokens can expire sooner, and are not refreshed remotely.

The worker suspends itself after five minutes without an active turn, queued
input, running durable job or recent attachment/submission. Waiting on the model and executing
tools count as active work. `lca fg` can remain attached while the VM sleeps; passive output polling
does not keep it awake. Entering a prompt wakes it. The timer runs inside the VM and works when the
local machine is offline. AWS's traffic-based idle policy is not enabled.

The worker saves its session and claims a shared gate before requesting
suspension. New prompts are atomically published under that gate. While it is
closed, the client retains its stable-ID outbox, waits for AWS suspension/resume,
and retries publication. The resume hook reopens the worker's gate. `lca fg`
and `lca local` wake a suspended VM automatically. A terminated VM is reported
as expired; it is never silently replaced or replayed.

The execution role needs only this additional permission (substitute your image):

```json
{
  "Effect": "Allow",
  "Action": "lambda:SuspendMicrovm",
  "Resource": "arn:aws:lambda:ap-southeast-2:ACCOUNT:microvm-image:IMAGE"
}
```

AWS authorizes this action at image scope: this grants suspension of VMs from
that image, not IAM isolation to just the caller's VM. The worker targets only
its configured VM ID. It obtains short-lived execution-role credentials through
IMDSv2 and uses the existing curl SigV4 support. No local AWS credentials or
additional SDK are copied into the VM. Request configuration is private, removed
after the request, and never printed or placed in process arguments.
A definitive refusal leaves the worker awake. An ambiguous suspension result
is retried at most three times with the gate closed; a confirmed resume cancels
retries. If uncertainty remains, the gate stays closed pending a resume hook, rather than risking starting work
as the machine freezes. Unexpected controller failures require inspection.

Suspension stops compute charges but incurs snapshot storage and read/write
charges. It does not extend the eight-hour lifetime or refresh model credentials. `/local` terminates it automatically after successful return. Collection stops the worker, not VM billing: run `lca stop`
after collecting. `lca stop --discard` explicitly terminates without collection.
Durable S3 checkpoints preserve completed turns and queued input. Recovery holds
started but uncheckpointed inputs for review rather than replaying uncertain work.
There is no heartbeat-based failover or automatic multi-VM rollover.

Offline checks:

```bash
make local
make test TESTS='tests/test_background.lua tests/test_session.lua tests/test_tui.lua microvm/test_lifecycle.lua microvm/test_foreground.lua'
eval "$(luarocks --lua-version=5.5 path --bin)"
python3 -m unittest discover -s microvm -p 'test_*.py'
```

Image garbage collection is host-side maintenance, independent of local sessions.
Configure the exact image LCA owns and an explicitly validated rollback:

```json
"image_gc": {
  "image_arn": "arn:aws:lambda:ap-southeast-2:ACCOUNT:microvm-image:IMAGE",
  "rollback_version": "7.0",
  "automatic": true
}
```

After a successful `/bg`, or when entering `lca fg`, LCA starts a detached GC check
at most once per 24 hours. There is no daemon or scheduled AWS service: if you do
not use remote mode, nothing runs. Missing configuration, missing CLI or unavailable
credentials skip cleanup. Automatic failures go to `<config-path>.gc.log` and do
not interrupt attachment. Failed credential attempts also observe the cooldown.
Set `automatic` to false to disable opportunistic cleanup.

```bash
lca gc                 # preview only; no AWS writes
lca gc --apply         # clean now, bypassing the automatic cooldown
```

GC preserves the configured default, validated rollback, every version used by a
nonterminated VM (including suspended VMs), builds in progress, and versions newer
than the default. It requires both protected versions to be successful and active.
After validating a replacement, update `image_version` and set `rollback_version`
to the previous validated default. Merely building another image does not make it
the prepared default.

Candidates are deactivated, confirmed inactive, and checked again against AWS VM
usage and the current config before deletion. A newly observed user protects a
candidate and restores its prior activation status. Deletions are confirmed via
AWS, not inferred from an API acknowledgement. A partial failure stops cleanup;
a candidate may remain inactive and need inspection before retrying. A local lock
serializes collectors using the same config; this is not a distributed deployment
lock, and operators must not reactivate retiring versions concurrently.

Image cleanup only removes versions of the explicitly configured managed image.
Recovery backups use S3 Lifecycle independently of LCA: objects under `recovery/`
expire 31 days after creation, superseded versions expire after one day, and expired
delete markers are removed. The 31-day window covers the current eight-hour VM
maximum plus 30 days of recovery. Each handoff gets a fresh prefix. If sessions
become longer-lived, revisit this policy before extending their lifetime.
There is no separate seven-day return policy or client-side backup deletion loop.
Expiration is asynchronous and individual objects may disappear at different times;
recovery is not guaranteed beyond the retention window.

Before uploading a new backup, LCA ensures these two named rules exist, preserving
unrelated bucket rules. The host needs s3:GetLifecycleConfiguration and
s3:PutLifecycleConfiguration when setup is needed. S3 then expires backups even
when LCA never runs again. Existing objects under that prefix are also subject to
the policy. The runtime role does not need lifecycle management permissions.
Local-only use never checks or changes AWS. `lca gc` remains image-only cleanup;
it does not delete local recovery files or experiment evidence.

Backup storage is automatic on first `/bg`: LCA uses
`lca-recovery-<account-id>-<region>`, creates it if absent, blocks public access,
enables default AES256 encryption, installs lifecycle rules, and grants the
configured execution role access only to `recovery/` (deletion only for rotating
snapshots). It then saves the selected bucket in the local MicroVM configuration.
An explicitly configured `checkpoint_bucket` is respected. Setup uses the host's
AWS identity and needs bucket creation/configuration and PutRolePolicy permissions;
no AWS calls occur for local-only sessions. Access-denied errors do not cause LCA
to claim another account's bucket or silently disable backups.
