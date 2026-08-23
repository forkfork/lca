# Rill

Rill is a local-first deployment preview and release coordination CLI written in
Python. It turns a repository's `rill.yaml` manifest into a dependency-aware release
plan that developers can inspect before anything changes.

The two primary commands are:

```bash
rill plan                 # render the proposed release graph; never mutates targets
rill apply --approve ID   # execute one previously stored plan
```

Rill stores plans and execution receipts in `.rill/state.db` using SQLite. Target
adapters currently support Docker and Kubernetes. It has no hosted control plane and
does not apply a plan automatically.

Useful starting points:

- `src/rill/cli.py` — command parsing and user-facing output
- `src/rill/planner.py` — manifest validation and dependency graph construction
- `src/rill/executor.py` — approved-plan execution and receipts
- `src/rill/adapters/` — target-specific Docker and Kubernetes operations
- `docs/architecture.md` — boundaries and end-to-end flow

Development uses `pytest`; package metadata and console entry points live in
`pyproject.toml`.
