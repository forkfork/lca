# Why Build Your Own Coding Harness?

LCA began with a simple belief: coding agents become much easier to understand once
you build the loop yourself.

A basic harness is not a mysterious new kind of software. It is a program that sends
messages to a model, notices when the model asks to use a tool, runs that tool, returns
the result, and repeats. The first useful version can be small. The interesting work
comes from making that loop reliable without making it incomprehensible.

Building one is valuable for four reasons.

First, it is an unusually good way to learn how coding agents actually work. A finished
agent product hides decisions about prompts, tool schemas, context, concurrency,
editing, retries, and completion. Implementing the loop turns those hidden choices
into things you can inspect and reason about.

Second, it gives you control. The model supplies a great deal of intelligence, but the
harness determines what the model can see, what it may change, which errors it must
observe, and what counts as proof. Small harness decisions can matter more than another
paragraph in the prompt.

Third, it lets you become a participant rather than only a consumer. You can test a
new edit protocol, change how several tool calls are scheduled, expose different
evidence, or reject a fashionable technique when it does not improve your work. You
are no longer limited to the switches another product decided to expose.

Finally, a harness is an experimental instrument. Because you own the boundary around
the model, you can preserve traces, replay tasks, compare alternatives, and learn which
ideas actually help.

This is not an argument that everyone should replace mature coding agents. It is an
argument that the machinery is approachable, educational, and strategically useful.
The best way to stop treating an agent as magic is to build the smallest one and then
earn its complexity one failure at a time.

## The nouns of a harness

Before discussing LCA's design, it helps to name the pieces.

| Noun | Meaning |
| --- | --- |
| Model | The system that interprets the task, reasons about it, and proposes actions. |
| Provider | The API and transport used to send requests and receive model output. |
| Instructions | The stable policy that tells the model its role, tools, boundaries, and expected behavior. |
| Message | One piece of conversation history: user text, assistant output, or a tool result. |
| Context | The bounded set of messages and instructions sent on the next model call. |
| Tool | A capability exposed by the harness, such as reading a file, editing it, searching, or running a command. |
| Tool call | A structured request from the model to invoke a tool with particular arguments. |
| Tool result | The correlated evidence returned after that call executes. |
| Scheduler | The harness logic that decides which calls may run together and which must wait. |
| Agent loop | The repetition of model call, tool execution, returned evidence, and another model call. |
| Session | The durable conversation and configuration that survive across turns. |
| Harness | Everything that owns this loop: prompts, tools, scheduling, context, recovery, verification, and UI. |

The model is only one component. The harness connects the model to reality.

```text
                         ┌──────── context ────────┐
                         │                         │
user task ──► messages ──► model ──► response ──► tool calls
                         ▲                         │
                         │                         ▼
                         └──── correlated results ◄── tool runner
```

If the response contains no tool calls, the loop ends with an answer. If it contains
calls, the harness executes them, appends their results, and asks the model what to do
next.

In deliberately simplified pseudocode, the conceptual core is almost this small:

```text
messages = [user_task]

loop:
    response = model(messages, instructions, tool_schemas)
    messages += response

    if response has no tool calls:
        return response text

    for call in response tool calls:
        result = validate and execute(call)
        messages += correlated result
```

That is enough to make a primitive coding agent. Everything below exists because a
primitive agent eventually encounters reality.

## 1. One tool call changes the nature of the program

A chat interface exchanges text. A coding harness allows model output to cause an
effect. The moment a `read`, `edit`, or `run` call can execute, model output becomes an
input to a real API.

Even one tool therefore needs a contract:

- a unique name;
- a schema for its arguments;
- validation before execution;
- a bounded result;
- an explicit error state;
- and an identity connecting the result to the original call.

LCA's first tool protocol embedded XML-like calls inside assistant text:

```text
<tool_call name="read">{"path":"src/main.lua"}</tool_call>
```

This was easy to see and easy to prototype. It could also be parsed while the response
streamed. But executable control data and prose shared the same channel. Examples
could look like calls, tags could be incomplete, trailing prose could appear after a
call, and a large file write could produce a huge stream of argument text. We added
parsing, duplicate suppression, early stream cutoffs, and partial-response handling.
The simple protocol was slowly becoming its own unreliable language.

GPT-5.6 Sol gave LCA a cleaner boundary through native function calls. The provider
returns a structured item containing the tool name, arguments, and `call_id`. The
harness returns a `function_call_output` with that same ID. Assistant prose is no
longer confused with executable intent.

The migration was not merely replacing XML syntax. Native calls changed how streaming,
history, sanitization, and results worked. In one failed turn, a tool output reached
the provider without its matching call after history had been slimmed. The provider
correctly rejected the request with HTTP 400. We learned that a call and its result are
one protocol transaction: they must remain pair-atomic during storage, compaction,
replay, and final request construction.

The XML work was still useful. It taught us the requirements that survived the
encoding: validate executable intent, preserve identity, bound output, reject malformed
work clearly, and never treat generated text as trusted merely because it came from a
strong model.

## 2. Tool results are evidence, not blobs of text

The model needs to understand what happened after a call. A plain stdout string is
often not enough.

A command may fail to start, time out, be cancelled, exit non-zero, or succeed after
producing partial output. A read may discover that a file is absent. An edit may reject
stale source without changing anything. These outcomes should not all look like “some
text came back.”

LCA grew a small execution lifecycle:

```text
start(call_id, tool, arguments)
        │
        ├─ progress(elapsed time, output growth)
        │
        └─ finish(summary, content, error state, duration, policy evidence)
```

This structured result serves several purposes. The model receives reliable evidence
for its next decision. The TUI can show whether work is moving. A later reviewer can
distinguish an actual harness failure from a surprising but intentional policy.

Error meaning also depends on the operation:

- A missing optional file during discovery can be useful information.
- A stale edit is a safe refusal and should perform no write.
- A failed mutation should block a dependent verification command.
- A command timeout should terminate the owned child process.
- Missing credentials or an externally owned port may be environmental blockers, not
  application defects.
- Cancellation should preserve the last known-good state.

The lesson is simple: errors are part of the tool API. If the harness flattens them
into prose, it forces the model to reconstruct facts the runtime already knew.

## 3. Several tool calls turn the runner into a scheduler

The easiest loop executes one tool call, returns its result, and asks the model again.
That is reliable but slow. A repository investigation may need several independent
reads and searches whose arguments are already known.

Sol can emit multiple native calls in one response. This removes unnecessary model
round trips, but it creates a scheduling problem.

```text
model emits: read A, read B, edit C, run tests

read A ─┐
        ├─ safe concurrent discovery
read B ─┘

edit C ─── must observe the relevant source
   │
   └────── run tests only after the edit succeeds
```

Blind concurrency is incorrect. The harness must understand enough about each tool to
classify relationships between calls:

- Independent reads and searches may run together.
- Mutations to different files may be independent.
- Several edits to one unchanged snapshot may be grouped only when their ranges do not
  overlap.
- A read and write of the same file cannot safely race.
- A command that verifies a mutation depends on that mutation succeeding.
- A later action whose arguments depend on an earlier result belongs in a new model
  round.

LCA therefore preserves call identity, model-call batch, and emission position. It
executes the coherent independent prefix, returns all correlated results, and lets the
model continue when a real dependency requires new reasoning.

We also bound read concurrency, total read-result bytes, and repeated discovery. More
parallelism is not automatically more intelligence; unbounded discovery can flood the
context faster than it saves latency.

The rule we kept is:

> Run work together when its arguments are already known and its effects are
> independent. Start another reasoning round when the next action depends on evidence.

## 4. Editing deserves its own design

Reading is observational. Editing changes the user's source. Treating both as generic
shell commands throws away an important safety boundary.

A coding model commonly reads a file, reasons for several seconds, and then proposes
an edit. The source may have changed during that interval, or the model may be pointing
at text that occurs more than once. LCA treats the earlier read as evidence and makes
the edit conditional on that evidence still being true—similar to compare-and-swap.

We tried several edit interfaces rather than assuming the familiar one was best:

- Whole-file writes are excellent for creating small files, but too destructive and
  verbose as the default for existing files.
- Exact search-and-replace looked promising, but controlled comparisons showed that
  its apparent advantage came from unrelated mistakes. Ambiguous matches remain a
  fundamental problem.
- Generic patch formats are familiar to developers, but still require generated
  coordinates, a parser, and recovery from failed application.
- Transactional multi-hunk edits work well when several distant changes against one
  snapshot are already known. The model did not select the tool reliably enough to
  justify exposing its larger schema on every normal turn.
- Tagged range edits identify the expected source endpoints and fail closed when the
  evidence is stale or ambiguous.

LCA kept tagged range edits as the normal interface. It also made strict failure cheap
to recover from:

- A uniquely identifiable unchanged range may relocate by a small line offset.
- Grep can return bounded tagged source suitable for a direct edit.
- A stale-edit error includes a tiny fresh tagged window for the next attempt.
- Compatible non-overlapping edits against one snapshot can apply transactionally.
- Syntax checks reject a bad candidate without replacing the original file.

The recurring pattern is to keep the write boundary conservative while making a safe
retry inexpensive.

## 5. Recovery belongs inside the loop

Real coding work fails constantly in small ways: a tag goes stale, a process exits, a
provider socket stops responding, a command is unavailable, or the model proposes an
invalid sequence of calls.

A robust harness does not need a bespoke branch for every possible failure. It needs
to preserve enough structured evidence for the next decision and to protect state
while recovery occurs.

LCA uses several layers:

- Tool validation prevents malformed work from executing.
- File mutations fail before writing when their evidence is stale.
- Dependent calls are skipped after a prerequisite fails.
- Provider requests have first-byte, idle, and absolute deadlines.
- WebSocket failure can fall back through a bounded transport path.
- Foreground commands support cancellation and kill their owned process tree on
  timeout.
- Long-lived servers and watchers become durable jobs with IDs, bounded output, status,
  waiting, and explicit stop operations.

Recovery must also be visible. A retry policy that can wait for many minutes while the
interface remains unchanged is operationally correct but experientially broken. The
user needs to know whether LCA is waiting for the model, retrying transport, running a
command, or genuinely unable to proceed.

## 6. Context is working memory, not an archive

Every model call includes a bounded context. Long tasks accumulate file contents,
command output, old failures, tool protocol items, and conclusions that may no longer
describe the worktree.

It helps to separate three things:

- The session is the durable record of what happened.
- The active context is the evidence useful for the next decision.
- The worktree remains the authoritative source and can be read again.

Early LCA compacted only after a complete user turn. But one user turn can contain many
model/tool cycles, so it could cross the limit before the outer turn ended. Reserve
checks now happen inside the loop before every model request.

Context transformation is protocol work, not merely text summarization. Native tool
calls and outputs must remain correlated. Recent file evidence must not disappear
while an edit still depends on it. Changing an old prompt prefix can also destroy
provider cache reuse even when it saves tokens.

Recent traces reinforced that aggressive compaction is not automatically safer. An
88k-token request was far below Sol's configured input limit; its failure came from an
invalid native call/result pair, not context exhaustion. The better policy is graduated
reduction based on actual usage and causality, rather than compacting early because a
large number looks uncomfortable.

LCA also starts interactive sessions fresh by default. Prior project sessions can be
resumed explicitly, but old conversation is not silently treated as current evidence.

## 7. Verification answers a question

An agent should not run tests merely to generate green symbols. Verification exists to
resolve uncertainty introduced by the task and the changes made.

We learned to distinguish:

- a transient environment failure that needs a rerun but no code change;
- a reproducible application failure that needs a mutation and a relevant check;
- a missing external dependency that cannot be repaired inside the repository;
- and sufficient existing evidence, after which more checking only adds latency and
  opportunities for confusion.

Verification becomes invalid when later code changes. LCA therefore ties proof to the
mutation sequence rather than treating one old successful command as permanent.

We rejected both extremes: “always run everything” wastes time, while a universal
small command budget can skip necessary evidence. The retained rule is to gather
distinct evidence until the active uncertainty is resolved, then stop.

## 8. Evaluations are part of harness engineering

Harness choices often feel compelling in one anecdotal run. Controlled tasks are
needed to learn whether they improve finished work or merely change its style.

Our evaluations also failed in instructive ways. Some rewarded exact LCA tool names
rather than equivalent evidence. Some assigned the final exit code of a compound shell
command to every subcommand. Others counted generated cache files as agent mutations
or rejected a correct explanation expressed differently.

The research discipline we kept is:

- Grade final behavior and workspace state first.
- Separate correctness, evidence, safety, efficiency, and latency.
- Preserve trajectories and workspaces so a corrected grader can re-evaluate old runs.
- Use negative controls so a complex-task optimization does not make simple work worse.
- Change one harness variable at a time.
- Treat skipped required work as failure, not speed.

This discipline prevented several attractive ideas from shipping without evidence:

- Automatically attaching source around every traceback added context but did not
  remove later reads.
- Adding containing-declaration context to grep did not improve the next action.
- Wider stale-edit windows added material without changing behavior.
- A permanently visible multi-edit tool increased schema complexity without reliable
  selection.
- Hiding plans did not reliably reduce total rounds; the model spent them elsewhere.
- Persistent context receipts would duplicate recent-read guards unless they prove
  value across real compaction boundaries.

A green baseline and no production change can be a successful research result. A
harness should not become a museum of rules for problems the model already handles.

## 9. External research supplies questions, not answers

Maintainer posts, papers, repositories, issues, Hacker News, Reddit, and social media
are useful discovery feeds. They have pointed us toward stale-edit recovery, context
rebasing, deferred capabilities, long-running orchestrators, and other worthwhile
questions.

Popularity is not evidence that a technique fits LCA. We use public discussion to
find mechanisms, prefer primary implementations and reproducible traces, and then test
the idea locally. Project text, source, paths, and credentials never belong in search
queries.

Ideas that did not ship are recorded alongside successful ones so later work does not
continually rediscover the same fashionable dead ends.

## 10. Investigate observed friction before proposing improvements

The automatic self-research reviewer and its controlled challenger workflow were
removed after failing to produce useful improvements. River summaries now expose
actual tool activity, failures, concurrency, and repeated arguments. `/river` and
raw run logs provide the evidence for a separate investigation session.

Repeated arguments are observations, not proof of waste. A proposed improvement
still needs a concrete mechanism and a controlled evaluation before adoption.
The standalone evaluation harness remains available for that work.

## 11. The interface should show what the harness knows

The TUI is a view of the loop, not a decorative dashboard.

A static checklist can imply progress while revealing nothing about evidence. LCA's
destination remains stable while the path responds to actual events: reads sharpen the
approach, edits pull files into the work, failures bend the path back, and verification
moves it toward proof.

Long commands originally left the display unchanged because output was buffered until
completion. Foreground tools now emit bounded elapsed-time and output-growth
heartbeats. The interface can say that work is alive without inventing a percentage.

The river follows the same rule: event marks and counts describe recorded tool
activity. Decorative palette changes never imply success or failure.

The desired aesthetic can remain organic, wobbly, and playful. Truthfulness concerns
what drives the motion, not whether the motion looks like a business process.

## The compact version

Building LCA changed our view of coding agents:

- A harness is a comprehensible loop, not magic infrastructure.
- Tool calls are untrusted API requests and results are correlated evidence.
- Multiple calls require dependency-aware scheduling, not blind concurrency.
- Editing deserves a stricter interface than ordinary command execution.
- Recovery, cancellation, and progress are normal parts of the loop.
- Context is causal working memory, not a transcript that should grow forever.
- Verification should resolve uncertainty and then stop.
- Evaluations must judge outcomes rather than reward harness-specific rituals.
- External research proposes questions; local evidence decides what ships.
- Self-improvement is safe only after the underlying loop is observable and
  recoverable.

The point of building a harness is not to own the most code. It is to understand and
control the boundary where model judgment becomes action. LCA's emerging philosophy is
adventurous in what it tries, conservative in what it claims, and explicit about the
evidence that moves it from one to the other.
