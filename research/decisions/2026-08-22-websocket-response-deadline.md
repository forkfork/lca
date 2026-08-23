# WebSocket response deadline

## Decision

Enforce the provider's absolute total deadline inside the WebSocket transport,
and cap an individual WebSocket response attempt at 180 seconds before the
existing HTTP fallback path gets its chance.

## Evidence

During `auth_api/mental_plan`, repository implementation and verification had
completed, but the final request remained on a reused WebSocket until the
15-minute scenario timeout. The provider already supplied idle and total
deadlines. The transport enforced the idle deadline for each frame read but
ignored the total deadline, so periodic control frames could prevent an idle
timeout indefinitely.

After enforcing one request-wide deadline and applying the shorter WebSocket
failover budget, the replay completed and the deterministic grader passed it at
score 100 in 236.6 seconds.

## Follow-up signal

The replay returned 2.28 MB of WebSocket event data for 10.6k output tokens.
One 15.7 KB native `write` response produced 3,858 argument-delta events and
873 KB of response bytes over 95.8 seconds. Measure this amplification before
choosing between event coalescing, a different large-write tool contract, or a
cqueues/lua-http transport; do not attribute it to agent reasoning alone.
