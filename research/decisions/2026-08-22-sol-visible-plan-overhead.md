# Sol visible-plan overhead

## Decision

Do not hide or remove `update_plan` from broad Sol implementation tasks based on
the current evidence.

## Pilot evidence

The `sol_plan_overhead` mental-plan pilot passed `auth_api` at score 100 with no
failed mutations, but required 16 model calls and 17 tool calls. The recent
post-batching visible-plan run passed at score 100 in 15 model calls. Removing
visible plan calls therefore did not reduce total rounds; the trajectory spent
the budget on additional implementation and inspection calls instead.

An earlier attempt reached passing repository verification in seven calls but
then hung on its final response and hit the scenario timeout. That run is not
valid plan-quality evidence because it never produced a trajectory or grade. It
did expose and motivate the WebSocket absolute-deadline fix.

## Interpretation

Standalone plan calls are not automatically wasted calls. They may organize a
broad trajectory even though the tool itself has no repository side effect.
Prompting Sol not to report a plan is too indirect and too variable to act as an
efficiency mechanism.

The theory remains in the suite so it can be rerun if plan reporting can later
be combined with useful work in the same response or represented without a
separate model continuation.
