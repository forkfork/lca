# Agent Notes

- After changing Lua source, scripts, bins, or rockspecs, run `make local` so the local LuaRocks install matches the checkout.
- For behavior changes, run the narrow relevant test first, then `make test` when the change touches shared code.
- Use `make check` when you want both the local LuaRocks install and the full Lua test suite.
- LCA run logs are written under `/tmp/lca/logs`. When debugging a bad UI/tool run, start with the matching timestamped `lca-*.log`, inspect the raw assistant/tool protocol around the failure, and replay parser edge cases from that captured text when possible.
