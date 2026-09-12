# Whole LCA inside a Lambda MicroVM

Experimental packaging and whole-session handoff. LCA, workspace and tools all
live in the application container inside the VM. See [the handoff guide](HANDOFF.md)
for `/cloud`, `/bg`, setup and recovery, and [the original registered screen](EXPERIMENT.md)
for the initial deployment experiment.

The [completed results](RESULTS.md) document successful AL2027 snapshots and a
real coding task in Sydney, including the native ARM64 portability fix.

## Why both Lua and Python?

This directory contains code for two machines: the user's local host and the
MicroVM. File language alone does not tell you where a file runs.

| Where | Language | Responsibility |
| --- | --- | --- |
| Local host | Python | AWS setup and image builds (`first_run.py`, `storage_setup.py`, `package.py`), shell transport and handoff (`handoff.py`), workspace transfer/reconciliation, backup recovery, and image GC |
| Local host | Lua | Animated remote-session UI (`foreground.lua`), driven by the Python transport (`foreground.py`) |
| MicroVM | Lua | Readiness/resume hooks (`bootstrap.lua`), the LCA agent loop and queue (`worker.lua`), S3 checkpoints (`checkpoint.lua`), and idle suspension (`lifecycle.lua`) |

Python was an expedient choice for the experiment's archive handling, AWS CLI
orchestration, and WebSocket transport. It is not an architectural requirement.
The tradeoff is a second host runtime and control code split across two languages.
The host currently needs Python 3.12+, `websockets` 15+, and a current AWS CLI for
remote mode; ordinary local LCA sessions do not use this Python control path.

**Python and the AWS CLI are not required inside the MicroVM.** The whole agent
runs there in Lua and executes commands against its local workspace. Its small
AWS lifecycle/checkpoint helpers use curl with temporary execution-role credentials.
The bootstrap readiness listener does not execute agent tasks.

## Discovered dependencies

| Component | Requirement / reason |
| --- | --- |
| Lua | PUC Lua 5.5 (`>=5.5,<5.6`); AL2027 provides 5.4.8, so build pinned 5.5.0 |
| LuaRocks | 3.13.0, supports Lua 5.5 headers; install system-wide in `/usr/local` |
| Rocks | luasocket 3.1.0-1, luasec 1.3.2-1, lua-cjson 2.1.0.10-1, luv 1.52.1-0 |
| Native | `agent.crypto` needs OpenSSL 3 EVP digest/MAC; LuaSec needs libssl/libcrypto; luv builds bundled libuv with CMake; LuaSocket/cjson use libc/libm |
| Build | GCC, make, CMake, OpenSSL headers, libxcrypt headers; curl, tar, gzip, unzip for source/rock installation |
| Tools | git-core (HTTPS Git), ripgrep; `sh`, coreutils (`stty`, `timeout`, `ls`, etc.), findutils, grep, procps (`pkill`), `/bin/kill` from util-linux-core; diffutils for coding work |
| TLS | CA bundle at `/etc/pki/tls/certs/ca-bundle.crt`, already recognized by both LCA transports; AL2027's own openssl-snapsafe-libs |
| Paths | `/usr/local/bin` first; both `lua` and `lua5.5`; system-wide rocks avoid host-specific Lua paths |
| Writable | HOME `/root`, `/workspace`, `/tmp/lca/logs`; workspace sessions/jobs write dotfiles/directories |
| Config | Normally `~/.lca-credentials.json`; use explicit temporary `--credentials` for this screen. No host MCP config copied |
| Terminal | Interactive frontend needs a PTY, `/dev/tty`, `stty` and ANSI terminal; batch `lca run` needs no PTY |
| Excluded | Node, Python, AWS CLI, wget, SSH server are not runtime requirements for this Codex-backed slice. Python is needed on the host for remote setup, transport, transfer, recovery and testing |

The source has no `lca --version`: that flag goes to the interactive argument
parser. Use `luarocks show lca --mversion` and `source-manifest.json` to identify
the exact `dev-1` checkout. Do not interpret the unsupported flag as an image bug.

## Base image and snapshot boundary

Official preview: `public.ecr.aws/amazonlinux/amazonlinux:2027`, version
`2027.0.20260903`, manifest-list digest
`sha256:a6c4227aac90ecad487ee5fc82849b2d043659fffed35fd68473c262e2a96e94`.
The Dockerfile pins that digest. It uses DNF5 and swaps normal OpenSSL libraries
for the preview's `openssl-snapsafe-libs` 3.5.7 package. No SELinux adjustment.
`BASE_IMAGE` is an explicit switch for a future justified control; changing it
still requires checking that distribution's package names and compatibility.

Lambda's managed VM base is separate:
`arn:aws:lambda:ap-southeast-2:aws:microvm-image:al2023-1`.
The API currently exposes `ARM_64`. Local validation therefore uses ARM64 too.
The snapshotted process loads only LuaSocket and serves readiness and resume hooks on
9000. No credentials or live model/TLS session exist at snapshot time. LCA is
launched fresh through AWS's provided shell after restore.

The native ARM64 test exposed a lua-cjson 2.1.0.10 pointer bug: its empty-array
lightuserdata is masked to 47 bits but compared with an unmasked address. On the
VM's high library mappings this produced invalid replay JSON (`"annotations":`).
The same binary under QEMU did not expose it. LCA now uses the supported
empty-array table metatable in response normalization, with a regression test.
This is a general portability fix; no AWS conditionals are added.

## Freeze and build locally

```bash
python3 microvm/package.py /tmp/lca-microvm-context
docker build --platform linux/arm64 -t lca-microvm:al2027 /tmp/lca-microvm-context
docker run -d --name lca-microvm-local --platform linux/arm64 lca-microvm:al2027
docker exec -it lca-microvm-local bash
```

On x86 Linux, Docker needs ARM64 emulation. Docker documents registration with
`docker run --privileged --rm tonistiigi/binfmt --install arm64`; this modifies
host binfmt registration, not the image or AWS VM. Remove that registration
afterward with the same helper's `--uninstall qemu-aarch64` if installed only for
this experiment.

`package.py` copies only runtime source, bootstrap and fixtures, preserving
uncommitted source edits. It refuses symlinks, omits `.git`, host configuration,
credentials, logs and arbitrary workspace files, and writes a content manifest.
The resulting ZIP has `Dockerfile` at its root and is also the local build context.

## Temporary model credentials

Use only the current Codex access token, account ID and expiry, without the
refresh token. Transfer after launch over authenticated AWS shell ingress into
a mode-0600 temporary file outside `/workspace`; pass its path with
`--credentials`. Do not print the token or put it in command arguments/history.
Delete it before termination. Expiry requires a new token transfer; this is
deliberately not a production secrets design. Never copy `~/.aws` or `~/.ssh`.

`python3 microvm/credentials.py MICROVM_ID` performs that transfer from the
default LCA credential file (or pass a different file as a second argument).
It waits for echo/history to be disabled before sending credential bytes and
writes `/tmp/lca-model-credentials.json`. Run this only after VM launch.

Run `/bin/bash /opt/lca-microvm/smoke.sh simple /path/to/temporary-credentials`
and then the `coding` case. Preserve `/tmp/lca/logs`, both workspaces and the
shell transcript outside the VM before terminating it. The smoke script enables
the existing protocol recorder through Lua initialization, without changing LCA.

## AWS commands

Use a current AWS CLI v2 with the `lambda-microvms` service. The machine's old
2.22.9 lacks it; this run installs 2.36.44 under `/tmp/lca-microvm-tools`, without
replacing the host installation. Set `AWS_CLI` to that binary when using scripts.
All commands default to Sydney; no VPC or public SSH listener is created.

Provision a dedicated S3 bucket in Sydney, a build role and an execution role.
Both roles trust `lambda.amazonaws.com` for `sts:AssumeRole` and `sts:TagSession`,
with `aws:SourceAccount` constrained to your account. The build role needs
`s3:GetObject` only for the artifact bucket and CloudWatch log creation/writes
for this image's log group. The execution role needs no application permissions
for the basic Codex/HTTPS fixture. The session handoff extension adds
image-scoped `lambda:SuspendMicrovm` permission; see HANDOFF.md. See the
execution report for exact resource names.

```bash
export AWS_REGION=ap-southeast-2
aws lambda-microvms list-managed-microvm-images
bash microvm/aws.sh upload /tmp/lca-microvm-context.zip s3://BUCKET/context.zip
bash microvm/aws.sh create IMAGE_NAME s3://BUCKET/context.zip BUILD_ROLE_ARN
# Repeat status until image CREATED, version SUCCESSFUL and activation ACTIVE.
bash microvm/aws.sh status IMAGE_ARN 1.0
bash microvm/aws.sh run IMAGE_ARN 1.0 EXECUTION_ROLE_ARN
python3 microvm/credentials.py MICROVM_ID
python3 microvm/shell.py MICROVM_ID
# Inside the AWS shell (it starts in / with a zero-size PTY):
stty rows 24 cols 100
cd /workspace
bash /opt/lca-microvm/smoke.sh simple /tmp/lca-model-credentials.json
bash /opt/lca-microvm/smoke.sh coding /tmp/lca-model-credentials.json
rm /tmp/lca-model-credentials.json
exit
# Back on the host, after saving evidence:
bash microvm/aws.sh terminate MICROVM_ID
```

`shell.py` uses the host's Python plus `websockets==15.0.1` to forward terminal
bytes over AWS's shell endpoint, keeping its 15-minute token in memory. No code
server is installed in the VM. Termination is explicit; the one-hour maximum
lifetime also bounds an abandoned run. Save build/version errors and CloudWatch
logs before cleanup. Delete the image/version, artifact and dedicated IAM roles
when the experiment ends to avoid leaving snapshot storage behind.

## Sources

- [Official AL2027 container and DNF5](https://docs.aws.amazon.com/linux/al2027/ug/container-base.html)
- [Lambda image packaging and hooks](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html)
- [Snapshot/OpenSSL requirements](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images-snapshots.html)
- [AWS shell ingress example](https://github.com/aws/agent-toolkit-for-aws/blob/main/skills/specialized-skills/serverless-skills/aws-lambda-microvms/SKILL.md)
- [Docker ARM64 emulation](https://docs.docker.com/build/building/multi-platform/)

## Session handoff experiment

[HANDOFF.md](HANDOFF.md) describes `/background`, foreground reattachment,
queued input, automatic idle suspension/resume, ownership, recovery and return
to the original checkout. This is an
opt-in extension of the deployment slice, not part of its original success claim.
