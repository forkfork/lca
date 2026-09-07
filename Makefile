ROCKSPEC ?= lca-dev-1.rockspec
LCATUI_ROCKSPEC ?= /home/tim/git/lcatui/lcatui-dev-1.rockspec
LUAROCKS ?= /home/tim/.luarocks/bin/luarocks
LUA_VERSION ?= 5.5
LUA_INCDIR ?= /usr/include/lua$(LUA_VERSION)
LUA ?= lua$(LUA_VERSION)

.PHONY: local local-lcatui rock test check eval eval-list

local: local-lcatui
	@python3 scripts/test.py $(if $(filter 1,$(VERBOSE)),--verbose,) --label 'local lca' --command $(LUAROCKS) --lua-version=$(LUA_VERSION) --local make $(ROCKSPEC) LUA_INCDIR=$(LUA_INCDIR)

local-lcatui:
	@cd $(dir $(LCATUI_ROCKSPEC)) && python3 '$(CURDIR)/scripts/test.py' $(if $(filter 1,$(VERBOSE)),--verbose,) --label 'local lcatui' --command $(LUAROCKS) --lua-version=$(LUA_VERSION) --local make $(notdir $(LCATUI_ROCKSPEC)) LUA_INCDIR=$(LUA_INCDIR)

rock:
	$(LUAROCKS) --lua-version=$(LUA_VERSION) pack $(ROCKSPEC)

test:
	@eval "$$($(LUAROCKS) --lua-version=$(LUA_VERSION) path --bin)"; python3 scripts/test.py --lua '$(LUA)' $(if $(filter 1,$(VERBOSE)),--verbose,) $(TESTS)

check: local test

eval:
	python3 evals/run.py $(if $(SCENARIO),$(SCENARIO),all) $(if $(RUNS),--runs $(RUNS),)

eval-list:
	python3 evals/run.py --list
