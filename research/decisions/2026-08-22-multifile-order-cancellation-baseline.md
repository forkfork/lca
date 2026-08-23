# Multi-file order cancellation baseline

Date: 2026-08-22

## Decision

Keep the layered order-cancellation scenario as a whole-loop regression and add it to
the registered LCA-versus-Codex Sol comparison. Make no production runtime change
from this baseline alone. Both engines were fully correct after fixture and grader
calibration; the repeated LCA batch-cap signal should become a separate controlled
treatment.

## What the scenario tests

The fixture is an unfamiliar Python package with model, repository, service, and API
layers. The feature requires:

- a new cancellation domain state and backwards-compatible audit representation;
- validated and normalized request identity;
- per-order idempotency without duplicate audit events;
- conflicts for shipped orders and mismatched retries;
- consistent 400, 404, and 409 API mapping;
- preservation of existing shipping, query, serialization, and public imports.

The deterministic grader runs public and hidden behavior, limits changes to production
modules, requires service/API plus domain-or-repository participation, confirms that
at least three architectural layers were inspected before mutation, and requires
successful verification after mutation. A Codex judge can separately assess coherence
without controlling deterministic pass/fail.

## Calibrated comparison

The final comparison used three fresh runs per engine with GPT-5.6 Sol at low
reasoning on the identical clarified fixture.

| Engine | Passes | Score | Mean tools | Model calls | Mean latency | Mean prompt tokens | Mean verification | Mean estimated cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| LCA | 3/3 | 100 | 14.0 | 9.0 | 59.4 s | 90,219 | 2.0 | $0.1391 |
| Codex CLI | 3/3 | 100 | 5.3 | 1.0 | 48.6 s | 106,642 | 4.3 | $0.1487 |

Codex's tool and model-call accounting reflects a different interface: it performs
multiple shell operations within one long model turn, while LCA makes streamed native
tool round trips. Those counts should not be treated as a direct efficiency score.
The comparable findings are that correctness and scope tied, Codex was about 10.8
seconds faster, and LCA used fewer prompt tokens and a slightly lower API-equivalent
cost estimate.

## Calibration findings

An earlier Codex pilot produced misleading raw failures:

1. The original request-ID wording required validity “after trimming” but did not
   explicitly state normalized storage and comparison. Two implementations validated
   whitespace but preserved it. The contract now states the identity rule directly.
2. One fully correct implementation ran green tests and focused probes, then appended
   `git diff` in a non-Git eval workspace. The compound command returned nonzero even
   though verification passed. The grader now recognizes the successful test
   subcommand and has adversarial regression coverage.

The fresh post-calibration comparison passed 6/6, so no conclusion depends on
retroactively relabeling an ambiguous trajectory.

## Next experiment

Every LCA run hit the core four-call batch cap once while reading the README and four
architectural layers. Test a narrowly larger read-only discovery allowance or a
cap-aware continuation mechanism against this scenario plus smaller negative
controls. Accept only if correctness remains intact and model calls or latency fall;
do not raise mutation or shell concurrency merely because five initial reads are
useful here.
