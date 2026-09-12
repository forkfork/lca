-include config.local.mk

ROCKSPEC ?= lca-dev-1.rockspec
LUAROCKS ?= luarocks
LUA_VERSION ?= 5.5
LUA ?= lua$(LUA_VERSION)
# LuaRocks discovers headers by default; override LUA_INCDIR if needed.

.PHONY: local rock test check eval eval-list

local:
	@python3 scripts/test.py $(if $(filter 1,$(VERBOSE)),--verbose,) --label 'local lca' --command $(LUAROCKS) --lua-version=$(LUA_VERSION) --local make $(ROCKSPEC) $(if $(LUA_INCDIR),LUA_INCDIR=$(LUA_INCDIR),) $(if $(OPENSSL_DIR),OPENSSL_DIR=$(OPENSSL_DIR),)

rock:
	$(LUAROCKS) --lua-version=$(LUA_VERSION) pack $(ROCKSPEC)

test:
	@eval "$$($(LUAROCKS) --lua-version=$(LUA_VERSION) path --bin)"; python3 scripts/test.py --lua '$(LUA)' $(if $(filter 1,$(VERBOSE)),--verbose,) $(TESTS)

check: local test

eval:
	python3 evals/run.py $(if $(SCENARIO),$(SCENARIO),all) $(if $(RUNS),--runs $(RUNS),)

eval-list:
	python3 evals/run.py --list
