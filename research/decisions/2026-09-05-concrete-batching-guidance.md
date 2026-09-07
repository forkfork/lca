# Concrete batching and behavior-matched verification guidance

The user authorized implementing the improvements identified in the latest two
Snake turns and trying them. Added two native working-strategy instructions:
write implementation and test files together when their contents are known, and
group independent import/body replacements against the same inspected source.
Dependent edits must obtain fresh evidence after a prior insertion; stale-tag
validation remains unchanged. Added verification guidance favoring bounded real
UI/terminal smoke checks for interactive changes, honest untested boundaries, and
omitting redundant syntax checks after a test imported the changed module.

These are explicitly requested prompt changes, not a default promotion inferred
from a positive experiment. No tools, scheduling, or edit validation changed.

## Registered screen

`evals/theories/astra_concrete_batching_screen.json` registers four serial runs:
simple baseline/treatment followed by a randomized adjacent pair on the existing
multi-location edit fixture (seed 925: treatment first). Astra/high and normal
history are pinned; this reasoning setting differs from the reviewed interactive
log's default and is not a direct replay of that session. The only between-arm
factor is the pair of concrete batching instructions. New verification guidance
is present identically in both arms, so its effectiveness is not evaluated.

Budget: four launches, 360 seconds, $1.50 standard-equivalent between-run
threshold. Frozen Lua roots, fixtures, grader contracts, driver, runner, hashes,
raw requests/responses, observations, grades, workspaces, and analysis remain in
`evals/results/20260905-edit-batching-screen/`, outside model task workspaces.
The custom frozen-root runner is registered explicitly; the generic theory CLI
does not select these roots. Four known-good/known-bad grader checks passed before
live calls. No failed live attempts, retries, or omitted usage.

## Results

| Scenario | Arm | Pass | Seconds | Model rounds | Mutation rounds | Output tokens | Estimated cost |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Simple | Baseline | Yes | 2.274 | 1 | 0 | 5 | $0.040172 |
| Simple | Batching | Yes | 2.429 | 1 | 0 | 5 | $0.040912 |
| Multi-location | Baseline | Yes | 19.959 | 4 | 1 | 346 | $0.126664 |
| Multi-location | Batching | Yes | 19.728 | 4 | 1 | 355 | $0.114546 |

Both coding runs read three files together, submitted three edits together,
verified once, then answered. Both passed public/hidden behavior, scope,
surgical-edit and verification gates, with zero stale-tag failures. Total known
cost was $0.322294, a standard API equivalent, not subscription billing.

Outgoing request audits confirmed model/reasoning and treatment presence or
absence on every request. First prompts match after removing exactly the two
registered lines and normalizing temporary workspace paths; tools are identical.

Decision: no incremental behavioral activation. This screen does not justify
advancing an efficiency claim. The 1.2% coding latency difference is not evidence
of a speedup, and output tokens rose 2.6%. The fixture already batches under the
baseline; it neither changes line counts nor creates implementation/test files.
It therefore does not test those specific branches or real interactive checking.
The explicitly authorized guidance remains installed, with these limitations.
A future targeted comparison should recreate the import insertion plus body-edit
failure and independently grade a terminal smoke; do not repeat this insensitive
fixture to claim improvement.

## Local validation

Existing `tests/test_parallel.lua`: 20 passed, including grouped same-file edits.
`make check`: local LuaRocks install, full Lua suite, and all 109 Python tests passed.
The later new theory also passed manifest validation. Installed prompt module
bytes match the checkout. No new implementation-mirroring prompt tests added.
