# Hosted search evidence across local tool calls

Decision: retain the provider-level protocol repair. Request
`web_search_call.results` and serialize returned results as labelled external
tool evidence in a user input message immediately after the native search item.
Preserve the native item; do not treat external evidence as instructions or
accumulate synthetic messages in saved history. Preserve empty result arrays,
and do not manufacture results for older sessions that lack them.

The original evidence is `/tmp/lca/logs/lca-20260908-094758-19166.log.jsonl`,
calls `8:1` → `8:2` and `9:1` → `9:2`. Searches completed, but only search
metadata survived the local-tool continuation. The
[Responses reference](https://developers.openai.com/api/reference/python/resources/responses)
documents the results include option. Live verification showed that requesting
results alone was insufficient: the endpoint returned them and accepted their
replay, but the next model still reported no visible results.

Bounded contract checks are preserved under
`/tmp/lca-web-search-contract-20260908/`, including scripts, predeclared checks,
raw requests/responses and the failed answer check. Four completions used
`gpt-6-astra`, low reasoning. The initial two-call check verified result return
and replay acceptance after `printf local-check-ok`; its prompt withheld the
final answer. A subsequent answer check failed with native-item-only replay.
With explicit evidence text, the same answer check returned both expected URLs
and matching snippet paraphrases, with browsing disabled. An outgoing-request
audit confirmed exact preservation of the returned results in the evidence text.
The four calls reported 14,197 input and 427 output tokens in total.

This verifies the observed continuation contract, not general search quality or
an efficiency improvement. Making results visible consumes context: the answer
check grew from 166 to 4,556 input tokens. Old missing evidence cannot be recovered
by this change; those searches must be rerun. No change to server-side storage or
response chaining is needed.

Validation: provider regression tests, full Lua and Python eval tests, and local
LuaRocks installation passed using the home-directory Lua 5.5 toolchain.
