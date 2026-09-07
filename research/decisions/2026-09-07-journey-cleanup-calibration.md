# Journey cleanup: current coding calibration

Decision: further paired validation, not evidence of equivalence or a new adoption decision.

The user requested live coding evaluation after removing journey-specific prompt/schema/UI machinery while preserving concrete-change and verification guidance. The existing runner supports only the current prompt; this study measures current behavior, not the causal effect of cleanup. No historical control was substituted.

## Registration and validity

- Theory: `evals/theories/journey_cleanup_calibration.json`.
- Frozen campaign and evidence: `evals/results/journey-cleanup-20260907/`.
- Manifest SHA-256: `07783e9ec8523d742232667c2fe33cc06344202b8785731d34abcee49977b323`.
- Model: gpt-6-astra; reasoning high; current prompt; all tools; self-contained task suffixes; seed 907. Campaign fingerprint pins source, fixtures and graders.
- Limits: eight launches, $3 between-run standard-equivalent estimated-cost threshold (one-run overshoot possible), 600 active worker seconds.
- Initial offline registration failed because calibration requires two repetitions; corrected before any model calls. Final preflight: all 110 Python eval tests passed. Recovery grader tests cover good artifacts, broken artifacts and missing evidence; multi-file grader tests cover verification evidence acceptance/rejection, and fixture smoke rejects incomplete work. Full positive multi-file artifact calibration was not newly added.
- Two smoke cells, followed by six pilot cells. All eight completed; no retries, omitted failures, or unavailable usage.
- All 36 captured request prompts lack journey instructions and retain concrete changes/verification guidance. Campaign activation checks passed.

## Independent results

Every cell scored 100 and passed all its grader gates.

| Cell | Stage | Task | Seconds | Model calls | Tools | Estimated USD |
|---|---|---|---:|---:|---:|---:|
| 0000 | smoke | simple_prompt | 3.172 | 1 | 0 | 0.038972 |
| 0001 | smoke | failure_recovery | 47.082 | 7 | 10 | 0.218800 |
| 0002 | pilot | multifile_order_cancellation | 68.125 | 6 | 15 | 0.311560 |
| 0003 | pilot | simple_prompt | 3.421 | 1 | 0 | 0.038942 |
| 0004 | pilot | failure_recovery | 43.421 | 7 | 10 | 0.176656 |
| 0005 | pilot | multifile_order_cancellation | 74.724 | 6 | 14 | 0.332286 |
| 0006 | pilot | failure_recovery | 38.846 | 7 | 10 | 0.181186 |
| 0007 | pilot | simple_prompt | 2.487 | 1 | 0 | 0.038962 |

All three recovery runs observed an injected failed check, repaired the source and reran verification successfully, while preserving compatibility and file scope. Both multi-file runs inspected architecture before edits, modified three source layers, passed public and hidden idempotency/API/compatibility tests, and verified after editing. The simple control used no tools in all three runs.

Total campaign active worker time: 282.170 seconds. Total estimated cost: $1.337364, standard API equivalent excluding service-tier adjustments and hosted-tool charges, not actual billing. Usage: 341,885 input tokens (271,104 cached), 7,169 output tokens; 36 model calls and 59 tools. Per-cell usage, original grades, artifacts, raw protocol and configuration remain in the campaign directory.

## Interpretation

No current correctness failure was observed on these two coding fixtures. This is encouraging evidence that ordinary editing, multi-file implementation, verification and recovery remain functional without journey metadata. It cannot establish unchanged quality, performance savings, statistical reliability, or long-task planning quality. Smoke and pilot repetitions reuse fixtures, not independent task diversity. A fresh paired comparison with a frozen reconstructed pre-cleanup arm would be required for a causal claim. No additional runtime changes were made for this study.
