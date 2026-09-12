# Durable recovery and automatic storage setup

The previous VM died with AWS's `Internal service error`; the surviving local
project could be restored, but remote-only changes lacked a durable checkpoint.
The next host implementation then required a bucket field before backgrounding,
leaving users to choose infrastructure and leaving failed handoffs paused.

Remote setup now selects a private per-account/per-region recovery bucket,
installs S3 Lifecycle expiry, and grants the configured execution role narrowly
scoped storage access. Explicit bucket overrides remain supported. This setup
only runs on remote entry. Image 9.0 includes the durable worker; local config now
uses it, with image 8.0 retained as the previous deployment (it lacks backups).

Functional validation evidence lives outside the repository at
`~/.local/state/lca/experiments/20260912-durable-recovery/`:
registration.json, frozen context.zip, validate.py, validation.log, vm.json,
last-state.json, worker.log, terminated.json, recovered/, and grade.json.
One 512 MiB VM in Sydney, maximum lifetime 600 seconds, no model calls. Three
real shell commands produced three checkpoints. The VM was terminated while a
fourth command was running. Independent file/state assertions verified the last
completed contents, no partial fourth-command file, fourth input held as uncertain,
fifth input still queued, and exactly two rotating snapshots. AWS termination
was confirmed. This validates failure recovery mechanics, not arbitrary process
migration or long-running reliability; model behavior was not tested here.

Use this validated image for the experiment. Uploads occur before execution and
at complete command/turn boundaries. Storage failure pauses further work. S3
expires objects after 31 days without needing a running client. Long-lived
sessions beyond the current eight-hour VM maximum require revisiting expiry.
User data recovery is only guaranteed within the retention window; Lifecycle
expiration is asynchronous. Credentials are excluded from the archive.

Host validation: 59 Python tests passed, focused Lua background tests passed,
and the full Lua suite was run. Automatic provisioning was exercised against the
real account and persisted without requiring user bucket selection.
