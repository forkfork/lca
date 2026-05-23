#!/usr/bin/env bash
set -euo pipefail

type_text() {
  local text="$1"
  local delay="${2:-0.035}"
  local i ch
  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    printf "%s" "$ch"
    sleep "$delay"
  done
}

run_line() {
  local line="$1"
  printf "\033[96;1m$\033[0m "
  type_text "$line" 0.025
  printf "\n"
  sleep 0.45
}

laser_line() {
  local text="$1"
  local frames=${2:-34}
  local width=58
  local colors=(196 208 220 226 118 82 46 48 51 45 39 33)
  local bolts=(">" ">" ">" "*")
  local i col bolt pad

  for ((i = 0; i < frames; i++)); do
    col=${colors[$((i % ${#colors[@]}))]}
    bolt=${bolts[$((i % ${#bolts[@]}))]}
    pad=$((i * width / frames))
    printf "\r\033[K  \033[2m|\033[0m   \033[2m"
    printf "%*s" "$pad" ""
    printf "\033[1;38;5;%sm%s\033[0m" "$col" "$bolt"
    sleep 0.018
  done

  printf "\r\033[K  \033[2m|\033[0m   \033[2m> %s\033[0m\n" "$text"
}

mock_tool() {
  local color="$1"
  local name="$2"
  local desc="$3"
  local snippet="$4"

  printf "\r\033[K  \033[2m|\033[0m \033[%sm* %s\033[0m \033[2m %s\033[0m\n" "$color" "$name" "$desc"
  laser_line "$snippet"
  sleep 0.18
}

clear
printf "\033[97;1m┃  ┌─ ┌─┐\033[0m\n"
printf "\033[96;1m┃  │  ├─┤\033[0m\n"
printf "\033[36m┗━ └─ │ │\033[0m\n\n"
printf "\033[1mThis is my coding tool. There are many like it, but this one is mine.\033[0m\n\n"
sleep 0.9

run_line 'lca run "explain this project in 3 bullets"'
printf "\033[2m+-------------------- tools --------------------+\033[0m\n"
mock_tool "32;1" "find" "searching . for files" "README.md docs/architecture.md lua/agent/ui.lua"
mock_tool "32;1" "read" "reading README.md" "lca is a small coding tool with boring visible moving parts"
mock_tool "32;1" "read" "reading architecture.md" "terminal entrypoints create a session and tools return results"
printf "\033[2m+-- 3 tools (find, read) -----------------------+\033[0m\n\n"
sleep 0.7
printf "- small terminal agent with one-shot and REPL modes\n"
sleep 0.35
printf "- reads, searches, edits, writes, and runs commands in your repo\n"
sleep 0.35
printf "- keeps the tool loop visible instead of hiding it behind a dashboard\n\n"
sleep 1.1

run_line 'lca repl'
printf "\033[36;1mlca>\033[0m "
type_text "make the failing test pass, then show me the diff" 0.025
printf "\n\n"
sleep 0.7
printf "\033[2m+-------------------- tools --------------------+\033[0m\n"
mock_tool "36;1" "grep" "matching /TODO\\|FIXME\\|error/ in tests src" "tests/test_checkout.sh: expected empty carts to return zero"
mock_tool "32;1" "read" "reading test_checkout.sh" "assert_equal(total({}), 0)"
mock_tool "33;1" "edit" "editing checkout.ts" "if #cart == 0 then return 0 end"
mock_tool "35;1" "run" "running \`npm test\`" "OK checkout handles empty carts; totals still pass"
printf "\033[2m+-- 4 tools (grep, read, edit, run) ------------+\033[0m\n\n"
sleep 0.7
printf "\033[32;1mOK tests passed\033[0m\n\n"
sleep 0.4
printf "Changed one guard clause so empty carts return before totals are calculated.\n\n"
sleep 0.8

run_line 'git diff --stat'
printf " src/checkout.ts | 6 ++++--\n"
printf " 1 file changed, 4 insertions(+), 2 deletions(-)\n\n"
sleep 0.8
printf "\033[93;1mHeads up:\033[0m lca runs tools directly in the current repo.\n"
printf "Commit or stash the good stuff first.\n"
sleep 1.5












