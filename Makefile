ROCKSPEC ?= lca-dev-1.rockspec
LUAROCKS ?= luarocks
LUA_VERSION ?= 5.4

.PHONY: local rock test check

local:
	$(LUAROCKS) --lua-version=$(LUA_VERSION) --local make $(ROCKSPEC)

rock:
	$(LUAROCKS) --lua-version=$(LUA_VERSION) pack $(ROCKSPEC)

test:
	for f in tests/test_*.lua; do lua "$$f" || exit 1; done

check: local test
