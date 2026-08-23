# Architecture

Rill separates planning from execution so reviewing a deployment does not require
target credentials.

1. The CLI loads `rill.yaml` and sends it to the planner.
2. The planner validates services and builds a directed acyclic dependency graph.
3. A content-addressed plan and its approval status are stored in SQLite.
4. `rill apply --approve ID` reloads that immutable plan and dispatches its steps to
   Docker or Kubernetes adapters.
5. The executor writes a receipt for every attempted step, including failures.

The planner cannot call adapters, and adapters do not read manifests. This boundary
keeps plan generation deterministic and makes dry-run output usable in CI without
deployment credentials.
