# Decision: retain current loop after unavailable-runtime recovery baseline

## Decision

Keep the current LCA/Sol loop unchanged for the unavailable pinned-runtime failure
class. Retain `environment_recovery` as a cross-engine regression scenario and move
the next iteration to an ambiguous environment-versus-application failure.

## Contract

The fixture requests a focused change to an existing dependency-free Python package.
Its documented baseline command uses `python`. The eval runner prepends a
scenario-local executable that deterministically emits the error shape of a missing
pyenv 3.12.4 runtime and exits 127; the host's `python3` remains available. Both LCA
and Codex CLI receive the same PATH.

The deterministic grader requires:

- observation of that environment failure before mutation;
- a production mutation after the failure;
- public and hidden requested behavior;
- a later successful relevant verification through `python3`; and
- an exact one-file production scope, excluding tests, README, `.python-version`, and
  new files.

Grader contract tests prove equivalent LCA and Codex action vocabulary receives the
same result. They also reject correct code without an observed recovery and reject a
solution that changes `.python-version`.

## Five-run result

The preregistered `environment_recovery_baseline` comparison used GPT-5.6 Sol with
low reasoning and seed 840.

| Engine | Passes | Mean score | Mean latency | Mean commands | Mean tool calls |
| --- | ---: | ---: | ---: | ---: | ---: |
| LCA / Sol | 5/5 | 100 | 28.0s | 3.4 | 8.0 |
| Codex CLI / Sol | 5/5 | 95 | 35.9s | 6.0 | 7.0 |

Both engines passed every outcome, evidence, and safety gate. The five-point Codex
difference came only from the optional efficiency dimension. Several Codex traces
appended `git diff`, `git status`, or `git diff --check` to a compound verification
inside the deliberately non-git workspace. Tests and targeted assertions passed, but
the Git command returned nonzero, so Codex performed another clean verification.
LCA generally diagnosed the unavailable runtime, selected `python3` or its absolute
path, edited the target, and combined public and targeted checks without that detour.

Reported token totals are not a clean harness-cost comparison because Codex CLI and
LCA expose different rollout accounting. They remain diagnostic, not a quality gate.

## Implication

The user's observation that environment failures are important produced a useful
test, but this first case does not reveal a missing LCA mechanism. Adding prompt rules
or automatic recovery logic now would optimize an already-green path. The next case
must be more discriminating: for example, a verification failure whose output could
plausibly be caused by missing configuration or by incorrect application behavior.
It should test whether the agent gathers evidence and avoids rewriting production
logic to mask unavailable credentials or infrastructure.
