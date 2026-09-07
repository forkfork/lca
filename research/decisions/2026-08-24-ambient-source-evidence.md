# Ambient source evidence experiments

## Decision

Ship bounded evidence-bearing grep. Do not ship traceback source hydration, X-ray
reads, or persistent context receipts from this experiment.

The production grep interface remains the familiar search tool. Its result now
contains freshly tagged source windows and a content snapshot receipt, allowing a
matching range to be passed directly to `edit`. The enrichment is workspace-local,
ignores binary and files larger than 1 MiB, merges overlapping windows, and retains
the existing 20 KB output ceiling.

## Evidence-bearing grep

Theory: `evals/theories/evidence_bearing_grep.json`

The first six-run pilot used a natural instruction. Sol often read the tiny,
obviously named implementation directly, so only one of six trajectories used
grep. All six implementations were correct, but the pilot showed the mechanism is
an optimization for searches the model already chooses, not a reason to force
search into every task.

The controlled capability comparison then explicitly required content search and
ran three randomized control/treatment pairs. Both cells passed all behavior,
scope, and verification gates:

| Metric | Plain grep | Tagged grep | Effect |
|---|---:|---:|---:|
| Passes | 3/3 | 3/3 | equal |
| Mean model calls | 5.33 | 4.00 | -25% |
| Mean latency | 15.53 s | 12.58 s | -19% |
| Mean prompt tokens | 38,824 | 29,540 | -24% |
| Mean source reads after grep | 1.00 | 0.33 | -67% |
| Mean tools | 5.00 | 4.67 | -7% |

The treatment did not require prompt guidance to produce that result. Production
guidance now merely states the truthful interface contract: tagged grep ranges are
valid edit evidence.

## Traceback hydration

A separate randomized three-pair comparison passed behavior and scope in all six
runs, but Sol explicitly read the referenced source after every hydrated traceback.
Treatment and control both averaged eight tools and seven model calls. Hydration
increased mean latency from 25.19 s to 28.17 s and prompt tokens from 52,893 to
54,183. The prototype, option plumbing, tests, and disposable eval fixture were
removed.

## Deferred paths

LCA already skips exact repeated reads while their result remains visible. A more
persistent receipt system would need to prove value across compaction rather than
duplicate that guard. X-ray reads would add language-specific parsing and a new
selection mode. Neither has enough evidence to justify that abstraction yet.

## Stale-edit recovery update

The same ambient-evidence pattern was tested on `stale_edit_recovery`: when tags
are stale, the rejected edit returns a small current tagged window but still never
writes. Three randomized pairs passed all behavior, scope, annotation-preservation,
and verification gates. Treatment removed the recovery read in 3/3 runs, reduced
tools from seven to six and model calls from six to five, reduced mean latency from
21.52 s to 18.16 s, and reduced prompt tokens from 45,477 to 37,381. It ships by
default. Theory: `evals/theories/stale_edit_self_healing.json`.

Containing-declaration grep context was also tested and rejected. Both cells passed
3/3, but the extra signature did not remove any full-file read. Treatment increased
mean tools and model calls by 0.33, latency from 18.09 s to 24.48 s, and prompt
tokens from 31,256 to 35,100. All declaration heuristics and their disposable eval
fixture were removed.

A simpler two-line versus four-line window comparison also passed 3/3 in both
cells. Reads, tools, model calls, and prompt tokens were effectively identical;
four lines increased mean latency from 14.29 s to 15.49 s. The two-line default
and fixed constant remain, and the experimental option was removed.

## Transition census and stopping rule

After these experiments, 230 recent usable LCA eval trajectories were scanned for
redundant transitions within the next three completed tools. The raw candidates
were 26 failed-run-to-read transitions, 24 grep-to-read transitions, 12 repeated
same-file reads, 12 successful-edit-to-same-file-read transitions, and 10 stale
edit recovery reads. Inspection showed:

- failed-run reads are the mechanism where source hydration was rejected;
- grep reads commonly request the complete file, and both declaration context and
  wider windows failed to displace them;
- repeated reads are mostly intentional disjoint ranges in larger auth fixtures;
- most post-edit reads occur after a failed verification or non-Git diff command,
  not directly after the edit;
- stale recovery reads are eliminated by the shipped stale-edit evidence.

Across the complete saved corpus, only two successful edits were followed
immediately by a same-file read. Syntax-rejection-to-read occurred once, while a
second syntax rejection retried directly with the existing evidence. There is no
remaining frequent authoritative-tool transition that justifies another runtime
feature. Resume experiments when new trajectories establish recurrence instead of
constructing a fixture solely to force a speculative optimization.
