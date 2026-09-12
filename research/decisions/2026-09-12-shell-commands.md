# Explicit shell commands in the session environment

`!command` now shares the existing local job runner used by `/test`, without
changing the saved test command or invoking the model. Local and remote session
loops dispatch it at their existing queue boundaries. Bounded stdout/stderr tails,
exit status and full log paths enter the conversation as user-requested command
results. Each command uses a fresh shell in the session working directory.

Local regression checks cover cwd, stdout/stderr, exit 7, persistence through save
and load, unchanged test configuration, ordered execution through the real worker,
and rejection by the client when an old worker lacks support. The existing full
Lua suite and Python MicroVM tests passed. Remote history renders shell results
as command output rather than attributing them to the assistant.

The frozen build and command-only AWS validation are retained privately under
`~/.local/state/lca/experiments/20260912-bang-command/`. Image 8.0 built successfully
on the existing AL2027/ARM64/512 MiB configuration in Sydney. One VM with a
600-second maximum lifetime ran three queued commands. The first wrote a marker
and exited 7; subsequent commands read and appended to that marker, then listed
it. The resulting `firstsecond` contents, three completion records, three saved
shell results and unchanged test setting were checked independently of display
text. No model credentials were transferred. AWS confirmed VM termination.

Decision: enable this explicit command feature in prepared image 8.0. This is
functional validation, not a general reliability or performance claim. Existing
VMs on image 7.0 need a return-home/background cycle to gain worker support; they
are not hot-patched or restarted automatically.

Retention review: one named image has eight versions. Keep 8.0 as default and 7.0
as validated rollback and the version of an existing suspended user VM. Versions
1.0–6.0 are candidates under the proposed retention policy (2.0 is a failed build).
No versions were deleted and automatic image GC is not implemented. Future GC
belongs after validated preparation, must establish ownership, account for all
nonterminated VMs and coordinate retirement with concurrent launches.
