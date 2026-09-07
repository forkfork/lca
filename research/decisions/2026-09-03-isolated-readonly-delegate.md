# Isolated read-only delegate decision

Date: 2026-09-03

## Decision

Reject synchronous Terra delegation as a default harness optimization. Retain the
implementation behind `delegate_readonly_enabled = false` as an experimental boundary
for the next dependency-DAG treatment.

The capability itself is feasible: a cheap model can reason over an explicit bounded
evidence packet without receiving the parent conversation or gaining tools. The tested
scheduling shape is not efficient because it serializes child reasoning between two
full-context Sol calls.

## Treatment

`delegate_readonly` accepts one self-contained task and one to eight known repository
text paths. The harness resolves every path with `realpath`, confines it to the working
directory, rejects duplicate, binary, oversized, unreadable, and non-file inputs, and
caps the combined evidence at 32 KB. It numbers source lines, labels file content as
untrusted data, calls Terra/medium with `tool_scope = none`, rejects any nested tool
attempt, caps returned text, and records child usage in the parent tool event.

The schema and selection guidance are absent unless the session flag is enabled.
Control runs therefore do not pay for or see the experimental tool.

## Results

The preregistered matrix used three randomized runs per variant and scenario, with
model judging disabled so deterministic scenario graders remained authoritative.
All 24 runs passed. Delegate activation was 9/9 on repository tasks and 0/3 on the
simple negative control.

| Scenario | Control cost | Delegate cost | Cost delta | Control latency | Delegate latency | Latency delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| project orientation | $0.0504 | $0.0658 | +30.5% | 19.6 s | 29.8 s | +52.3% |
| ambiguous bug investigation | $0.0807 | $0.1165 | +44.3% | 39.2 s | 47.8 s | +22.0% |
| multi-file cancellation | $0.1373 | $0.1717 | +25.1% | 61.1 s | 70.3 s | +15.0% |

The simple negative control remained 3/3 with zero delegate calls, but the enabled
schema and prompt increased median estimated cost from $0.0155 to $0.0165 (+6.5%).

Median child usage was 386/588 input/output tokens for orientation, 823/443 for bug
tracing, and 2,562/833 for the layered implementation. Child cost was not omitted:
`estimated_total_api_cost_usd` includes both parent and Terra usage.

## Interpretation

Correctness and isolation survived, but every efficiency comparison missed the 10%
improvement requirement, and two of three repository latency cells exceeded the 20%
regression limit. The hypothesis is rejected without changing the production default.

For implementation tasks, delegation can remove broad source from the parent working
set, but the parent must still inspect tagged mutation targets and verify the result.
The added Sol round dominates the saved context. Orientation avoids those tagged reads,
yet Terra output cost and serial latency still outweigh the small parent-input saving.

The next experiment should change the scheduler, not merely strengthen selection
language: represent the delegate as a read-only DAG node that can execute alongside
independent reads/searches and join only before the first dependent mutation or final
synthesis. A Luna child is also worth screening, but only with the same isolation,
hard correctness gates, and combined-cost accounting.
