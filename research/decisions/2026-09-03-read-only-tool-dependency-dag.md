# Read-only tool dependency DAG decision

Date: 2026-09-03

## Decision

Reject the first read-only DAG treatment as a default optimization. Retain it behind
`tool_dag_enabled = false` because its execution semantics, failure behavior, and
cost reduction were proven, but its latency improvement missed the preregistered gate
and varied materially by task family.

## Mechanism

When enabled, native schemas for `ls`, `read`, `find`, `grep`, and
`delegate_readonly` gain optional `node_id` and `depends_on` fields. Other tools do
not expose these fields. Before execution, LCA validates unique IDs, dependency
references, and acyclicity. A malformed graph or any mutation/command node rejects
the entire graph before partial execution.

Every ready wave runs through the existing parallel executor. Shell-backed discovery
starts asynchronously and can overlap an isolated delegate. Later waves run only
after all dependencies complete; a failed dependency produces an explicit skipped
result for each descendant. Events record node ID, dependencies, wave, and skip state.

## Results

The preregistered matrix ran three randomized samples in each control/treatment cell:
24 runs total. All runs passed deterministic hard gates. DAG activation was 8/9 on
repository tasks and 0/3 on `simple_prompt`; delegate activation remained 9/9 and
0/3 respectively.

| Scenario | Serial cost | DAG cost | Cost delta | Serial latency | DAG latency | Latency delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| project orientation | $0.0681 | $0.0822 | +20.9% | 31.5 s | 33.6 s | +6.6% |
| ambiguous bug investigation | $0.1138 | $0.0988 | -13.2% | 55.4 s | 49.9 s | -9.9% |
| multi-file cancellation | $0.1837 | $0.1751 | -4.7% | 88.3 s | 114.3 s | +29.4% |
| pooled repository median | $0.1138 | $0.1020 | -10.4% | 55.4 s | 49.9 s | -9.9% |

Pooled median parent calls fell from six to five and tools from twelve to eleven.
The treatment therefore demonstrated real scheduling and cost leverage, but missed
the required 15% pooled latency reduction. The layered latency regression makes a
default promotion unsafe even though all outputs were correct.

A post-run isolation audit found that the first overlap refactor also allowed a
shell-backed discovery call to overlap a delegate in two of nine serial repository
controls. This can only make those controls faster, so it does not rescue the failed
latency gate. The executor was corrected and the full local suite rerun; non-DAG
batches now retain their original execution ordering, while overlap is enabled only
inside an explicit DAG wave.

## Next boundary

The strongest follow-up is not a broader DAG. It should reduce variance and schema
overhead: expose one compact `read_analysis_graph` tool rather than adding dependency
fields to five schemas, use a smaller bounded child response, and target only the
bug-tracing fan-in where replicated cost and latency both moved in the right direction.
That treatment must retain pre-execution validation, read-only scope, descendant
failure propagation, combined parent/child cost accounting, and a simple negative
control.
