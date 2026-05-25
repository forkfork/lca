# Learnings from Building lca

1. **Low-level network control is useful for debugging provider failures**

   When something goes wrong with an LLM provider, it is hard to tell whether the
   issue is the model, the API, the stream, a timeout, or the client library.
   Having direct control over the HTTP/SSE layer made failures easier to inspect
   and reason about.

2. **Context slimming can break prefix-based caching**

   Slimming the context window reduces token usage, but it also changes the
   prompt prefix. For providers with prefix-based caching, that can make cached
   tokens unusable. There is a tradeoff between keeping the conversation small
   and keeping the stable prefix intact enough for the cache to work.

3. **Parallel tool execution is necessary, but easy to get wrong**

   Running tools in parallel makes the agent much faster, especially for search
   and inspection. But it introduces ordering problems around reads, writes,
   edits, duplicate calls, and dependent operations. The tool runner needs
   explicit rules about what can safely run together.

4. **Tool calls are harder than they look**

   The model does not always produce clean tool calls. The agent has to parse
   partial output, ignore examples in prose, handle raw file content, avoid
   unsafe quoting, and separate executable calls from normal assistant text. Most
   of the reliability work ends up in this boundary.

5. **Long-running tasks create too much context unless output is controlled**

   Longer coding tasks produce repeated reads, command output, test logs, job
   status checks, and large tool results. Without limits, the context fills up
   quickly. The agent needs mechanisms to keep only useful output, summarize or
   discard old results, and make tool calls as small as possible.

6. **Some agent operations need to become jobs**

   Some useful operations do not fit a synchronous tool call model. Dev servers,
   watchers, slow tests, and long-running builds need to keep running while the
   agent continues working. Treating them as jobs gives the agent a stable handle
   for checking status, reading bounded output, waiting briefly, or stopping the
   process, instead of repeatedly blocking or polling a synchronous command.
