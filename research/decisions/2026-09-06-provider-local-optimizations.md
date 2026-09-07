# Provider local processing experiments

Pre-registered before measurement in `evals/results/20260906-provider-local-optimizations/registration.json`. Two independent semantics-preserving candidates: streamed-byte counting and single-pass diagnostic prefix hashes. Captured requests and original source are frozen with hashes; stream fragmentation fixtures are synthetic. No live model calls. Adopt only with exact semantic equivalence and measured local CPU improvement; do not infer model or end-to-end task speed.

## Decision: adopt byte counting and segmented hashing

The first hashing implementation checked each byte for a checkpoint. It failed the large-body regression gate (1 MB: 16.3% slower) and was rejected. A separately registered revision hashes disjoint spans between checkpoints; this avoids both redundant prefix passes and the per-byte branch. The byte-counter change replaces answer-so-far concatenation in both HTTP and WebSocket callbacks, preserving the existing chunk accumulator, byte limit, abort and callback behavior. Both final changes are installed directly, without flags.

Fresh validation, six alternating-order pairs per workload:

| Workload | Baseline CPU ms | New CPU ms | Change |
|---|---:|---:|---:|
| fingerprints-8192 | 0.230 | 0.156 | -32.3% |
| fingerprints-48000 | 2.324 | 1.035 | -55.5% |
| fingerprints-250000 | 8.154 | 5.710 | -30.0% |
| fingerprints-1500000 | 35.672 | 33.796 | -5.3% |
| fingerprints-captured | 1.080 | 0.648 | -40.0% |
| counter-http-2048 | 0.651 | 0.633 | -2.7% |
| counter-websocket-2048 | 0.438 | 0.444 | +1.3% |
| counter-http-65536 | 22.330 | 20.093 | -10.0% |
| counter-websocket-65536 | 17.950 | 15.829 | -11.8% |
| counter-http-196608 | 75.661 | 62.329 | -17.6% |
| counter-websocket-196608 | 62.577 | 46.931 | -25.0% |

All captured serialized requests and boundary-length/binary inputs produced identical hashes. Both transports matched output, callbacks, statistics, usage and exact/exceeded 200,000-byte cutoffs, including UTF-8 and NUL. Fresh stream cases changed lengths and fragmentation from 32-byte to 16-byte deltas. Permanent regression checks exercise both provider adapters through the normal complete API.

These are CPU measurements with mocked transport delivery, not network timings or measured model-task gains. Large synthetic streams expose quadratic copying; current short responses save much less wall time. No live requests or model costs. The benchmark preserved an invalid first WebSocket fixture run: connection reuse retained an empty fixture closure. That harness error was fixed before accepting evidence, explicit fixture activation checks were added, and all arms were rerun symmetrically. Original invalid measurements remain labeled separately.

All experiment variants and runners live only under the results directory, alongside frozen original source and original evidence. Active production has only the accepted implementation.

Final validation: provider unit checks and both-transport stream-limit regression passed; make check rebuilt the local LuaRocks install and passed the full Lua suite (including HTTP/WebSocket transport tests) plus 108 Python tests. Installed provider bytes match the checkout. Accepted source diff is preserved as accepted.patch with the evidence.
