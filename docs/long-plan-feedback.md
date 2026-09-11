# Long-plan feedback: an expedition with a field journal

Research and design note, 2026-09-11. This is a proposal, not an implemented
feature or an evaluation result. External observations below come from vendor
documentation and project READMEs, not hands-on comparative testing. They establish
available patterns, not that those patterns improve user comprehension.

## What other harnesses make visible

| Reference | Documented pattern | What I would take for LCA |
| --- | --- | --- |
| [Claude Code task list](https://code.claude.com/docs/en/interactive-mode#task-list) | Toggleable pending/active/completed checklist; tasks persist across compaction. Running shells and subagents have a separate view. | Keep the task's route distinct from the inventory of running tools. |
| [Claude Code settings](https://code.claude.com/docs/en/configuration) | Customizable spinner verbs and tips. | Personality can occupy a small space, but a playful verb cannot explain progress. |
| [Cursor Plan Mode](https://cursor.com/blog/plan-mode) | An editable plan with file references and todos; optionally saved in the repository. | Make the intended work a stable, inspectable object that the user can steer. |
| [Devin session tools](https://docs.devin.ai/work-with-devin/devin-session-tools) | Progress entries connect to shell commands, edits, and browser activity; command history supports navigation through the session. | A progress claim should lead directly to its evidence. |
| [GitHub agent sessions](https://docs.github.com/en/copilot/how-tos/copilot-on-github/use-copilot-agents/manage-and-track-agents) | Overview and logs support monitoring; follow-up prompts steer supported sessions. | Put orientation and intervention within reach of each other. |
| [OpenCode TUI](https://dev.opencode.ai/docs/tui/) | Thinking blocks can be shown or hidden independently of whether the model reasons. | Let people choose detail; a long reasoning transcript still needs orientation. |
| [Pixel Agents](https://github.com/pixel-agents-hq/pixel-agents) | Characters read, type, and signal waiting for input according to agent activity. | Attach whimsy to observable states. Pose can help recognition, but cannot convey the plan by itself. |

My synthesis: a useful display answers four different questions:

1. Where are we in the task?
2. What question or action is occupying the agent now?
3. What changed since I last looked?
4. Does it need me?

Tool throughput, elapsed time, and an animated spinner only partially answer these.
A plan checklist helps with the first question, but a step called "Implement" can
last twenty minutes. The missing layer is the short explanation of what is being
worked out *inside* that step.

## What LCA already has

The current [TUI](../lua/agent/tui.lua) accepts `update_plan` events, stores a plan,
and emits the focused step into the activity stream. It tracks tool lifecycle,
command output progress, working files, and edit recovery. The stream filter can
report model activity while suppressing thinking markup.

There is also task-marker rendering in `living_divider`, but the inspected
`divider_status` returns recovery states or quiet, not a task label. Existing
rendering machinery alone therefore does not establish a persistent plan display.
The TUI clears its plan at turn start, so continuity needs explicit handling.

The [plan tool](../lua/agent/tools/update_plan.lua) stores step text and one of
three statuses, allows at most one active step, and replaces the complete plan.
It has no stable step IDs, evidence references, or dependency edges. Legacy
`journey` metadata is explicitly discarded. A new design should use these facts
rather than assume an old journey system is still available.

The river already carries motion and character. The biggest opportunity is a
stable place for meaning that remains readable while activity moves underneath.

## Preferred direction: expedition map and field journal

Give the task a small, persistent route. A lantern marks the current waypoint;
completed waypoints remain visible; future ones have plain labels. The lantern
only travels when the active step changes. It can breathe gently while work is
ongoing, but elapsed time never moves it closer to completion.

An illustrative expanded terminal view, with invented task data:

```text
  Fix reconnect failures                         2 of 5 steps complete

  ✓ Reproduce ── ✓ Locate ── ◉ Repair ── ○ Verify ── ○ Explain
                             /\
                            /__\   camp 3 · Repair

  Investigating   Can the old timer fire after reconnect?
  Doing           Reading reconnect.lua and its callers
  Learned         The previous timer survives socket replacement
  Next            Cancel it when replacing the connection

  Journal
    14:32  Reproduced the failure                [test output]
    14:34  Located the surviving timer          [source]
    14:35  Added a cancellation check to plan    [plan revision]

  [expand plan]  [inspect evidence]  [steer]
```

Those controls are conceptual, not assigned keybindings. Preserve existing
Ctrl-T tool inspection when choosing actual controls.

The default view should take roughly three or four rows, not permanently consume
the transcript. An explicit expansion reveals the route and journal. On a narrow
terminal, retain the active step and plain text:

```text
  ◉ Repair · 2/5 steps complete
  Reading reconnect.lua · 18s
  Learned: old timer survives replacement
```

Use actual plan labels. Reproduce/Locate/Repair/Verify/Explain is an example,
not a mandatory sequence for research, writing, or every coding task. Long plans
need a window around the active step and explicit hidden-step counts. Do not
shrink twelve labels into unreadable dots.

### The part that feels like thinking

Prefer a short public work summary: the current question, a finding, or the
reason for changing direction. For example, "Checking whether reconnect leaves
an old timer alive" says more than "Thinking" or "Reading three files."

The model must supply that semantic summary explicitly. Do not infer it from
token rate, animation, filenames, or hidden thinking text. Until such a summary
exists, show the known plan step and observed action. If a summary is old, label
it "Last update" with its age rather than silently presenting it as current.

Keep three kinds of information distinct internally and visibly:

- **Intent:** the agent says it is investigating timer ownership.
- **Observation:** a command returned a failure, or a file was changed.
- **Interpretation:** the agent says the timer explains the bug, with an evidence link.

A successful shell command proves only that command's outcome. A completed plan
step is an agent assertion. Neither automatically establishes that the task is
verified. Display verification scope explicitly where available.

### Whimsy that carries information

| Event or state | Small visual gesture | Literal information alongside it |
| --- | --- | --- |
| New active step | Lantern moves to that waypoint | Step title |
| Model activity | Lantern gently flickers in place | Model working; last update age |
| New finding | A small star appears in the journal margin | Finding and evidence |
| Explicit plan revision | A dotted detour joins the route | What changed and why |
| Running command with no output | Companion sits by the lantern | Running 42s; no output for 31s |
| User input required | Companion raises a small flag | Needs your answer: … |
| Cancellation | Route ends with a pause marker | Cancelled; unfinished steps retained |

The companion could be a tiny moth drawn to the lantern. One little creature is
enough. It should feel like an occasional reward for looking, not a pet requiring
care. Labels remain ordinary language; avoid making people learn that "feeding
the mushrooms" means running tests.

Failures should retain their actual error and recovery information. Avoid comic
death scenes or celebratory motion while user action is required. Give motion
an off setting, preserve symbols and words without color, and provide ASCII
fallbacks. Freeze decorative movement while the user reads expanded history.

### Long-task cases that matter

- **Plan changes:** retain a revision entry and identify added/removed work. A
  denominator change is not a sudden loss of progress. Never present step counts
  as a percentage of time or effort remaining.
- **Quiet periods:** distinguish a running tool, model activity, a retry delay,
  and waiting for user input. Lack of output alone does not prove a hang.
- **Returning after ten minutes:** show completed steps, newest finding, current
  action, and unresolved blockers together. This is a main purpose of the journal.
- **Compaction and resume:** restore the task route from session state or recorded
  events; preserve its identity across turns. Mark historical summaries as such.
- **Parallel work:** if real child tasks exist, show labeled branches on expansion.
  Several concurrent tools are not necessarily several independent plan steps.
- **No plan:** show current action and recent findings. Do not fabricate waypoints
  simply to fill the visual.

## Other visual directions

**Observatory:** plan steps are named stars; the active one has an orbiting marker;
evidence forms a constellation. It suits the existing nightfall aesthetic, but
spatial position conveys ordering less directly and unrelated stars can suggest
dependencies that do not exist.

**Little workshop:** searching happens at a bookshelf, editing at a bench,
verification at a test rig. A character changes stations with tool activity.
This is immediately charming, but chiefly answers "what kind of action?" It
would still need a separate route and journal for long plans.

**Garden:** tasks become labeled plants and milestones change their form. It
offers a pleasant persistent record, but growth strongly implies monotonic
progress. Reopened work, removed steps, and uncertain scope are awkward to show.

I favor the expedition because detours, pauses, landmarks, and discoveries all
have readable equivalents. Its route can coexist with any river style; the
meaning of its markers should remain constant across themes.

## A bounded implementation direction

First expose the confirmed plan in a persistent compact view, with active tool
state, explicit waiting, and an expandable route. This can use existing events.
Avoid publishing a proposed plan from tool-start arguments as accepted state
before `update_plan` succeeds.

Then add a small structured public-update record for question, finding, next
action, and evidence references. Update on meaningful changes, not every token
or tool completion. Retain a bounded journal and link through to full history.
Stable step IDs and revision identity would make event association reliable;
matching edited plan text or array positions is insufficient for durable history.

Finally add the lantern and optional companion as projections of those states.
Keep animation out of semantic state changes, consistent with LCA's existing
advance/draw separation. A still frame should contain all essential information.

This note proposes design choices only. It does not establish usability benefits
or authorize adoption based on a screen. Any hypothesis experiment must first
follow `evals/EXPERIMENTS.md` and its registration and grading workflow.
