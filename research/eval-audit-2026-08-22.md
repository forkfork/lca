# Evaluation audit: 2026-08-22

## Why this audit exists

The first `project_orientation` grader confused answer quality, evidence quality, and
use of LCA-specific tools. It required exact `read` calls for two files and rejected
all shell execution, which means a strong Codex answer using bounded `rg`, `find`, and
`sed` discovery would fail. Terra's accurate one-document answer was also grouped
with zero-evidence answers. The resulting binary pass rates are not suitable for
model routing decisions.

## Current confidence by scenario

| Scenario | Confidence | What remains valid | Main problem |
| --- | --- | --- | --- |
| `project_orientation` | red | Raw answers, tool counts, tokens, and latency | Tool-interface-biased hard gates and conflated outcome/evidence score |
| `simple_prompt` | yellow | Detects the exact overthinking failure for a trivial arithmetic prompt | Rejects harmless answer formatting and is not normalized across engines |
| `ambiguous_bug_investigation` | yellow | Hidden cache behavior and final workspace scope are strong | Requires exact LCA `read` paths and `run` event text before editing |
| `auth_api` | green-ish | Black-box HTTP, persistence, expiry, throttling, and storage checks are substantive | Agent-authored test quality is weakly proxied by a command containing `test` |
| `batch_many_files` | green-ish | Exact output and scope checks are strong | Verification and communication checks are shallow diagnostics |
| `existing_codebase_edit` | green-ish | Public/hidden behavior and workspace scope are strong | Requires one prescribed three-file implementation shape |
| `repeated_text_edit` | green-ish | Exact behavior and workspace scope isolate the edit target | Does not hard-gate verification or unrelated rewrites within the target file |
| `stale_edit_recovery` | green-ish | Injected mutation, behavior, annotation preservation, and scope are strong | Trajectory metrics are LCA-tool-specific diagnostics |
| `failure_recovery` | green-ish | Deterministic injected failure, post-failure mutation, final behavior, and scope are strong | Recovery ordering is expressed in LCA event names |
| `context_boundary_edit` | green-ish | Latest correction, exact scope, and boundary treatment outcome are strong | `verification_performed` accepts any `run`, not a relevant green verification |

“Green-ish” does not mean independently validated. It means the grader's primary
claim rests on black-box behavior or final workspace state rather than prose or a
preferred tool sequence.

## Confidence in prior conclusions

### Quarantined pending corrected reruns

- GPT-5.5/Sol/Terra/Luna orientation pass rates and score ordering.
- The 5.6 orientation-specific grounding prompt. It directly optimizes the grader's
  prescribed README/architecture tool path.
- Fresh-versus-resumed orientation quality. Token-volume measurements remain valid;
  the quality comparison does not.

### Still supported, with bounded claims

- The unique-call and duplicate-call stream caps preserved exact output/behavior in
  controlled LCA runs while changing the intended transport boundary.
- Dependency-safe batch prefixing has a deterministic core-loop regression test.
- Intra-turn reserve checking has a causal forced-boundary control and final behavior
  checks. It does not establish real million-token compaction quality.
- Tagged versus exact edit conclusions remain limited to the tested mechanics. The
  hidden behavior and concurrent-change outcomes remain meaningful.
- Authentication, recovery, and investigation results show capability on their small
  fixtures, not general coding-agent superiority.

## Required repairs

1. Split outcome, evidence, safety, and efficiency scores. Only material correctness
   and safety failures should be universal hard gates.
2. Normalize semantic evidence across LCA tools and shell/native-tool agents.
3. Add grader unit tests containing strong alternatives, shallow guesses, false
   claims, unsafe activity, and different but valid tool paths.
4. Run Codex and LCA on the same fixture, prompt, model where possible, and grader.
5. Retain final workspaces for registered theory runs so grader changes can regrade
   historical trajectories.
6. Mark results with a grader version and fixture digest; never compare cells across
   different versions as though they were one experiment.
7. Calibrate qualitative thresholds against human-ranked examples before using them
   for model routing.
