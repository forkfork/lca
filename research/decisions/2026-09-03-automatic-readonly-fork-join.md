# Automatic read-only fork-join decision

Date: 2026-09-03

## Decision

Reject model-invisible automatic fork-join at the activation pilot. Keep the executor
path disabled as a tested research knob; do not run the remaining replication matrix.

## Treatment

Control and treatment expose identical prompts and native schemas. When enabled, the
executor may overlap shell-backed `ls`, `find`, or `grep` with `delegate_readonly` only
when every call in the already-emitted batch is read-only. A batch containing a command,
job, plan, or mutation retains serial behavior. Result events identify activated calls
and exactly one batch leader.

Focused tests prove actual overlap and prove that a mixed mutation batch cannot activate
the path. The full local suite passed.

## Activation result

The randomized one-run-per-cell pilot passed all eight deterministic graders. Both simple
cells used zero tools. The delegate activated on every repository task, but automatic
fork-join activated on 0/3 treatment repository runs: without DAG-specific prompting,
Sol never emitted a delegate and shell-backed discovery in the same response.

Because the treatment had no opportunity to affect execution, latency differences between
the cells are ordinary trajectory variance. The preregistered activation requirement was
not met, so another 16 live runs would not test the proposed mechanism and were stopped.

## Interpretation

The E32 reduction in parent rounds did not come from an invisible executor optimization.
Its model-visible batching instruction was necessary to create the flat fan-out. Scheduler
work alone therefore cannot improve the present delegate behavior. A future treatment must
either change selection/batching behavior explicitly or eliminate enough child overhead to
beat the actual parent-only harness.
