# Whole-agent Lambda MicroVM slice: successful

Date: 2026-09-12. Region: `ap-southeast-2`. The final image runs the complete
LCA agent, Git workspace, tools and tests inside one Lambda MicroVM. Both model
tasks completed through AWS's supported shell ingress. No remote executor or
control-plane abstraction was introduced.

## Image and runtime

The [dependency inventory and reproduction instructions](README.md) describe
the exact environment: Lua 5.5.0, LuaRocks 3.13.0, LuaSocket 3.1.0-1, LuaSec
1.3.2-1, lua-cjson 2.1.0.10-1, luv 1.52.1-0, LCA's OpenSSL binding, Git 2.55.0,
ripgrep 14.1.1, and the C/CMake/POSIX tools needed to build and use them.
No Python, Node or AWS CLI was needed inside the application container.

Official application base:

```text
public.ecr.aws/amazonlinux/amazonlinux:2027@sha256:a6c4227aac90ecad487ee5fc82849b2d043659fffed35fd68473c262e2a96e94
```

This is AL2027 public preview `2027.0.20260903`, using DNF5. The selected ARM64
manifest is `sha256:6b256061d973127677868b5ec8320d5de8fc5c0c2d0b92acf4d389edbc985ebb`.
Its own `openssl-snapsafe-libs-3.5.7-4.amzn2027.aarch64` replaces ordinary OpenSSL
libraries, following [AWS snapshot guidance](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images-snapshots.html).
No SELinux changes, extra OS capabilities, VPC or SSH server were needed.

The separate managed VM base was
`arn:aws:lambda:ap-southeast-2:aws:microvm-image:al2023-1`, version `1.0`.
Inside the restored VM, `/etc/os-release` says AL2027 and `uname` reports
`6.1.166-24.303.amzn2023.aarch64`. The preview's advertised kernel is therefore
not the kernel used by this application container.

Both image versions successfully snapshotted on **Graviton 3 and 4**. AL2023
application fallback was unnecessary and was not built. Final version `2.0`
was `SUCCESSFUL` / `ACTIVE` before launch. Its source manifest matched the local
tested image exactly:

```text
artifact context-v3.zip SHA256:
341b6b15146c14f2795f0872fda987bc8b6b57db68b22bdbad9f8a9842bac801
source-manifest.json SHA256:
ed6bd175de0cc9b6e5dead32351f80e9bc313fac566875acc3992c7ca9375204
```

The manifest hashes the actual working-tree sources, including edits that
already existed before this task; a Git revision alone is insufficient.

## Compatibility issue and minimal LCA change

The first VM's initial model call and its read/Git tools succeeded. Replaying
the response failed: WebSocket closed and HTTP fallback returned
`400 {"detail":"Bad Request"}` (Cloudflare request `a39b9dc67bc55e4f-SYD`).
The preserved wire body contains `"logprobs":,"annotations":}`: invalid JSON.

An offline reproducer in that VM returned:

```text
cjson.encode({a=cjson.empty_array})  -> {"a":}
cjson.encode(setmetatable({},cjson.empty_array_mt)) -> []
```

The [upstream implementation](https://github.com/openresty/lua-cjson/blob/2.1.0.10/lua_cjson.c)
masks lightuserdata to 47 bits when creating the empty-array sentinel but
compares it with the unmasked pointer when encoding. The VM mapped cjson near
`0xffff8afe0000`, while the sentinel was `0x7fff8b000b48`. The same `.so` SHA256
ran correctly under local QEMU's different address layout. This is a native
dependency/address-layout problem, not a snapshot failure or model-auth failure.

LCA's sole runtime change is in `normalize_array_field` in
[`lua/agent/providers/codex.lua`](../lua/agent/providers/codex.lua): represent
empty response arrays using the supported table metatable. There are no AWS
conditionals. A captured-response regression was added to
[`tests/test_codex_provider.lua`](../tests/test_codex_provider.lua).
It failed before the fix and passed afterward. All 32 provider tests passed on
the native VM; local `make check` passed the full Lua and Python eval suites.

The original screen stopped, preserved its failure, and was explicitly
[registered again](EXPERIMENT.md) with corrected source and fresh workspaces.
The diagnostic VM was terminated before the replacement was launched.

## Real task evidence

The task asked LCA to inspect the Lua clamp fixture, repair its boundary
behavior, run the existing tests, and inspect Git. On the final VM, protocol
records show three reads, one edit and two shell-tool calls across four model
calls. Those commands, files and tests were local to the VM. The agent changed
the two reversed return values in `clamp.lua`; the original tests and README
were unchanged.

Terminal evidence:

```text
clamp tests passed
independent exhaustive grade passed
 clamp.lua | 4 ++--
 1 file changed, 2 insertions(+), 2 deletions(-)
CODING_EXIT=0
```

The exhaustive grader checks all 9,471 combinations of integer value and bounds
in its declared range. Extracted artifacts were independently retested on the
host. Every final wire request parses as JSON and pins `gpt-6-astra`, reasoning
`medium`, tier `priority`. GitHub `git ls-remote` over HTTPS also succeeded.
The interactive LCA frontend started, displayed its prompt and exited via
`/exit` with `TUI_EXIT=0`; no additional model call was made for this UI check.

`lca --version` was attempted in both environments, but LCA has no such option.
`luarocks show lca --mversion` reports `dev-1`; use the manifest for exact identity.
AWS's shell starts in `/`, with HOME `/root` and a zero-size PTY. The test set
`stty rows 24 cols 100` and changed into `/workspace` explicitly.

### Screen accounting

Times are recorded agent intervals, not build/startup times or a performance
benchmark. Input counts include cached tokens. The failed row preserves known
usage from its first response; rejected follow-up request usage is unknown.

| Screen / case | Result | Model calls | Tool calls | Seconds | Input / output tokens |
| --- | --- | ---: | ---: | ---: | ---: |
| Original local / simple | pass | 2 | 2 | 9.811 | 14,913 / 114 |
| Original local / coding | pass | 4 | 6 | 15.670 | 31,582 / 343 |
| Original VM / simple | serialization failure | 2 logical | 2 | 11.970 | at least 7,360 / 71 |
| Corrected local / simple | pass | 2 | 2 | 10.029 | 14,915 / 120 |
| Corrected local / coding | pass | 4 | 6 | 22.986 | 31,646 / 370 |
| Corrected VM / simple | pass | 2 | 2 | 8.083 | 14,924 / 117 |
| Corrected VM / coding | pass | 4 | 6 | 14.003 | 31,637 / 359 |

There were seven agent invocations, including the failed one. The original VM
coding cell was not run. Known usage totals 148,471 tokens; incomplete requests
are additional unknown usage. The OAuth transport does not report per-run
monetary charges; no dollar cost is invented. AWS billed cost was not
queried. Each agent invocation had a 240-second limit; each VM had a one-hour
maximum lifetime and a 1 GiB baseline.

## Resources and commands

- S3: `lca-slice-20260912-146596105039-syd`, artifacts `context-v2.zip` and
  `context-v3.zip` (original and corrected source).
- IAM: `lca-slice-20260912-build` and `lca-slice-20260912-run` in account
  `146596105039`. Trust allowed Lambda assume-role/tag-session with SourceAccount
  constrained. The build role had artifact reads and scoped build-log writes;
  the execution role had no application permissions.
- Image: `arn:aws:lambda:ap-southeast-2:146596105039:microvm-image:lca-slice-20260912`,
  versions `1.0` and `2.0`.
- Diagnostic VM: `microvm-8dd726fc-bacb-330d-afb7-82fbbf3cc52b`.
- Successful VM: `microvm-47022c76-5ef1-3e12-a25b-40e41e3b82c4`.
- Networking: AWS-managed `SHELL_INGRESS` and `INTERNET_EGRESS` connectors only.

The small [`aws.sh`](aws.sh) script contains the actual create/update/run/
status/terminate CLI recipes. Artifact ZIPs have a root Dockerfile, as required
by [AWS's packaging model](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html).
[`shell.py`](shell.py) uses AWS shell tokens over WebSocket port routing to 8022.
[`credentials.py`](credentials.py) transfers only a current access token,
account ID and expiry after launch, while echo/history are disabled. It excludes
refresh tokens. Credentials were never part of an image or S3 artifact, and were
deleted from each VM and the host's temporary staging directory afterward.

Raw evidence is retained at
`~/.local/state/lca/experiments/20260912-microvm/`: frozen ZIPs and manifests,
registrations, dependency/build output, AWS responses, both shell transcripts,
raw model requests/responses, original malformed records, independent grades,
and extracted Git workspaces. `microvm-proof-success.tgz` is the final exported
proof; `microvm-v2-summary.json` contains its metrics. The TUI transcript is
large because it retains animation frames.

Cleanup completed: both VMs were confirmed `TERMINATED`; the image returns
`ResourceNotFoundException`; the dedicated bucket and both IAM roles were
confirmed absent. Temporary credentials and the added ARM64 binfmt registration
were removed. Local Docker images/build cache remain for inspection, containing
no credentials. Exact cleanup audit: `cleanup.json` in the evidence directory.

## Decision

**Further validation:** this slice establishes that whole-agent LCA tasks can
run inside an AL2027 application container on Lambda MicroVMs in Sydney, with a
small bootstrap and normal local tool execution. It does not establish long-task
reliability, persistence or suspend/resume correctness. Native ARM64 validation
remains necessary even after a passing emulated-container test. No larger
architecture was implemented or selected.
