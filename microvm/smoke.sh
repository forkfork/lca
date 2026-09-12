#!/bin/bash
set -euo pipefail
case "${1:-}" in
    simple) prompt='Read README.md and run git status --short. Describe the repository purpose in one sentence. Do not edit files.' ;;
    coding) prompt='Inspect this repository, fix clamp.lua to meet the README contract, and run the relevant tests. Use Git to inspect your change. Do not change test.lua or README.md.' ;;
    *) echo 'Usage: smoke.sh simple|coding credentials-path' >&2; exit 2 ;;
esac
credentials=$(realpath "${2:?credentials-path required}")
workspace="/workspace/$1"
test ! -e "$workspace"
mkdir -p "$workspace"
cp /opt/lca-microvm/fixture/* "$workspace/"
cd "$workspace"
git init -q
git -c user.name='LCA experiment' -c user.email='lca@example.invalid' add .
git -c user.name='LCA experiment' -c user.email='lca@example.invalid' commit -qm fixture
lua5.5 -v
luarocks show lca --mversion
git --version
rg --version
# The batch entry point does not enable transcripts itself. Enable LCA's existing
# recorder only in the agent process, leaving launcher probes/jobs untouched.
export LUA_INIT_5_5='if arg and arg[0] and (arg[0]:match("agent.lua$") or arg[0]:match("lca%-agent$")) then require("agent.core").set_transcript("/tmp/lca/logs/microvm-" .. assert(os.getenv("LCA_SMOKE_CASE")) .. ".log") end'
export LCA_SMOKE_CASE="$1"
timeout --signal=TERM --kill-after=10 240 lca run "$prompt" \
    --credentials "$credentials" --model gpt-6-astra --reasoning medium --service-tier priority
# Grade artifacts independently of the agent's answer, including hidden cases.
git diff --exit-code -- README.md test.lua
if [[ "$1" == coding ]]; then
    lua5.5 test.lua
    lua5.5 -e 'local c=require("clamp"); for lo=-10,10 do for hi=lo,10 do for x=-20,20 do assert(c(x,lo,hi)==math.max(lo,math.min(hi,x))) end end end; print("independent exhaustive grade passed")'
    test -n "$(git diff -- clamp.lua)"
else
    test -z "$(git status --porcelain --untracked-files=no)"
fi
git diff --stat
