# Build the reusable image on first backgrounding

A new user previously needed to prepare an image manually, even though storage
setup was automatic. First `/bg` now creates roles and storage, packages installed
LCA, submits one idempotent image build, waits for SUCCESSFUL/ACTIVE, and saves the
image for reuse. It explains the first-use delay. A lock and persisted request
prevent duplicate builds after interruptions. Local-only use makes no AWS calls.

Validation used a separate configuration in Sydney and created no VMs or model
calls. Evidence, registrations, failed attempts and repaired artifacts are under
`~/.local/state/lca/experiments/20260912-first-bg/`. The initial installed-package
build failed because LuaRocks deploys Lua sources to share/lua rather than keeping
the staging lua directory. A diagnostic retry of the same artifact also failed.
The packager now resolves exactly the Lua modules declared in the installed
rockspec, includes native/build source, and checks required inputs before upload.
A synthetic installed-layout regression test covers this behavior without a Git
checkout. The repaired artifact built and loaded LCA in an ARM64 Docker container,
then AWS successfully built/snapshotted version 3.0. A subsequent configuration
call reused that image. Temporary AWS image/roles/artifacts were removed afterward;
the user's existing prepared image was not changed.

Decision: use automatic first-build setup for this experimental flow. This is
functional provisioning validation, not a model-quality or launch-time benchmark.
63 Python tests, focused Lua background tests and the full Lua suite passed.
`make local` updated the installed package. Existing images are reused; upgrading
LCA does not silently rebuild them. Failed builds preserve diagnostic state rather
than creating an unbounded chain of images. AWS credentials, a sufficiently new
AWS CLI, host Python/websockets, and IAM provisioning permissions remain required.
