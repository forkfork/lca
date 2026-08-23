# Read-only discovery cap

Date: 2026-08-22

## Decision

Raise LCA's wholly read-only batch allowance from five to six calls. Keep the general
batch cap at ten and leave mutation, shell, dependency, total-turn, read-byte, and
repeated-read safeguards unchanged. Retain a session-level override so the behavior
can be tested without repeatedly changing production constants.

## Hypothesis and boundary

The layered order-cancellation baseline showed the same core cap event on every LCA
run. Raw trajectories established that Sol requested seven independent reads:
README, model, repository, service, API, tests, and public imports. Five admitted the
requirements and four production layers but deferred both tests and imports. Six
admits the tests while still deferring the lower-value import listing.

This treatment does not increase arbitrary concurrency. It applies only when every
call in the model response is one of LCA's read-only inspection tools. Any batch with
an edit, write, run, job mutation, plan update, or other non-read-only action uses the
unchanged general boundary and existing dependency logic.

## Results

Three observations per multi-file cell, including the audited pilot, produced:

| Read cap | Passes | Mean tools | Mean model calls | Mean latency | Mean prompt tokens | Mean verification | Mean estimated cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 5 | 3/3 | 14.7 | 9.0 | 61.8 s | 93,607 | 1.33 | $0.1501 |
| 6 | 3/3 | 13.7 | 7.0 | 50.2 s | 70,918 | 1.00 | $0.1349 |

The treatment reduced model calls by 22%, latency by 19%, prompt tokens by 24%, and
the cost estimate by 10%, while all behavior, architecture, scope, and verification
gates remained green. Every six-cap run still recorded one cap event because the
seventh import read was deferred; the improvement comes from admitting the test file,
not from removing the inventory boundary.

Negative controls were deliberately included:

- The ordinary three-file edit passed 3/3 in both variants, always used four model
  calls and one verification, and had no failed mutations or scope violations. Six
  admitted one additional read and was 8.5% slower (27.8 versus 25.6 seconds), within
  the registered 10% tolerance.
- The simple prompt passed 3/3 in both variants with one model call and zero tools.

## Tradeoff

Six is not universally faster. Small edits that already fit within five reads can
pay for one extra source result without reducing a round trip. The larger scenario's
repeatable two-turn and 11.6-second improvement outweighs that modest small-task
overhead because the extra slot crosses a useful information boundary: tests become
available before implementation and verification planning.

Do not infer that seven or an uncapped read batch would improve further. In this
fixture the seventh request was less valuable, and the cap still serves as protection
against broad inventory and context flooding.

After installation and the full test gate, a standalone run using the production
default passed at score 100 with seven model calls, 14 tools, six relevant source
reads, one verification, and no failed hard gate.
