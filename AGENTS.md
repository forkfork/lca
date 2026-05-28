# Agent Notes

- After changing Lua source, scripts, bins, or rockspecs, run `make local` so the local LuaRocks install matches the checkout.
- For behavior changes, run the narrow relevant test first, then `make test` when the change touches shared code.
- Use `make check` when you want both the local LuaRocks install and the full Lua test suite.
