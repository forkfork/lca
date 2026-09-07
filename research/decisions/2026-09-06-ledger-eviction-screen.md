# Aggressive transcript eviction with deterministic execution state

## Registered contrast

Both arms receive a harness-maintained evidence ledger. The control retains its
entire normal history; the treatment deletes assistant/tool history after every
completed batch, keeping original user messages and the ledger. Exact current
read ranges are checked against files. Command receipts retain exact arguments,
result, and local file revision. Plan acknowledgements cannot erase prior command
receipts. Raw events and before/after context views remain outside the workspace.
No model-written memory protocol, extra model, command-result reuse, or production
flag is introduced. This tests marginal eviction conditional on this ledger;
it does not compare the ledger against normal LCA.

The six-run screen contains one simple control and two coding pairs (concurrent
regression recovery, multifile order cancellation), Astra/high, full tool schemas,
current prompt. Gates: all tasks/activation pass, >=25% fewer aggregate coding
input tokens, <=10% latency and cost regression, <=1 extra model call per task.
Budget: $1.75 between-run standard-equivalent threshold and 360 active seconds.
A positive result only buys broader validation; it cannot promote a default.

## Audit correction

V1 stopped after two simple runs and one passing control coding artifact. Snapshot
JSON encoded empty provider array fields as objects; the actual request retained
correct arrays. The exact message-equality checker falsely rejected this. V2
normalizes only the named provider array fields, with positive/negative tests.
All completed v1 cells were checked symmetrically under the fixed auditor and
passed; original grades and the original halted state were not overwritten.
V1 cost $0.553664 is retained, and no v1 cells are pooled into v2 effects. V2 uses
fresh seed 931, controls, source fingerprint and immutable manifest. Original
source and results are preserved under evals/results/20260906-ledger-eviction-screen;
v2 under evals/results/20260906-ledger-eviction-screen-v2. All executable
interventions are confined to these frozen evidence checkouts.

## Results

V2 collection stopped at the registered between-run cost threshold, after five of six launches. All five completed artifacts and activation audits passed. The final multifile history-ledger control was not launched. Reject this implementation: the recovery pair already fails the input-token, latency, cost and model-round gates; aggregate paired coding effects are unavailable. Offline checks passed ledger invalidation/correction/plan
cases, known-good and broken graders, and 107 Python harness tests. The normal
checkout was reinstalled with make local; no production source was changed.

| Task | Arm | Seconds | Model calls | Tools | Input tokens | Estimated cost |
|---|---|---:|---:|---:|---:|---:|
| simple_prompt | history-ledger | 2.371 | 1 | 0 | 7427 | $0.041112 |
| simple_prompt | ledger-only | 2.281 | 1 | 0 | 7426 | $0.041102 |
| failure_recovery | history-ledger | 28.641 | 7 | 8 | 70707 | $0.309378 |
| failure_recovery | ledger-only | 66.588 | 14 | 16 | 133763 | $0.610860 |
| multifile_order_cancellation | ledger-only | 139.342 | 23 | 51 | 269409 | $1.432858 |

V2 spend $2.435310; audit-stopped v1 $0.553664; all attempts $2.988974. The $1.75 threshold is checked between runs, so the $1.432858 multifile treatment overshot it; no next run was launched. No usage is missing. Original grades, manifests and runs remain unchanged.

## Mechanism review

The eviction treatment removed history 13 times in recovery and 22 times in
multifile work. It retained correct final artifacts without model-authored memory
JSON, but did not deliver efficiency. Recovery repeatedly read the same files
before editing and reran successful verification. It took 14 calls versus 7,
133,763 input tokens versus 70,707, and 66.588 seconds versus 28.641.

The multifile view already omitted README at ledger-step-0002: the reverse-recency
10,000-byte read budget selected six other source ranges. Steps 3–7 retained eight
ranges from only six paths, confirming duplicate cache entries. The agent explicitly
said the requirements were missing in responses 6 and 7. Later command arguments
and result tails consumed the 16,000-byte ledger limit, evicting most current source
again. This is a retention-policy defect in this prototype, not a universal
negative about deterministic state. The archive was available, but retrieval and
repeated inspection did not amortize its cost on these tasks.

The next distinct implementation should pin the task's referenced requirements,
deduplicate file ranges, separate durable command receipts from the active source
budget, and preserve a small current action/observation window. Test that working-set
policy on the captured failure before more paid runs. A further experiment should
also compare against ordinary LCA: this screen only isolates eviction relative
to ledger-plus-history. Do not reuse these results as proof of whole-system gains.

No production behavior or runtime flag was added. The prototypes remain solely
inside frozen results/evidence checkouts. Final source fingerprints and all five
saved request/protocol audits match the manifest.
