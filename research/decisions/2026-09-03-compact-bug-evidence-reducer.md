# Compact bug evidence reducer decision

Date: 2026-09-03

## Decision

Reject compact Terra and compact Luna delegation for default or targeted routing. Retain
the bounded profiles as disabled experimental substrates. Production remains parent-only.

## Treatment

The existing isolated file packet, path confinement, byte limits, cancellation, no-tool
scope, and nested-tool rejection remain unchanged. Compact children return at most five
cited findings, three authoritative target spans, and explicit gaps, with a 3,000-byte
hard output cap. Terra/medium and Luna/medium were compared directly with parent-only
Sol/high on ambiguous bug tracing; `simple_prompt` was the negative control.

Eval accounting now prices each child from the model recorded on its tool event. This
corrected an earlier Terra-only costing assumption before any live candidate result was
accepted.

## Results

The activation pilot was encouraging: all six cells passed, compact Terra was 22.9% cheaper
and 11.1% faster than its parent-only sample, and compact Luna's child returned only 141
tokens. The preregistered fresh replication did not preserve that latency signal.

All 18 replicated runs passed. Both compact profiles activated in 3/3 bug runs, while all
9/9 simple runs used zero tools and zero delegates.

| Bug-tracing variant | Total cost | Latency | Sol calls | Tools | Child output |
| --- | ---: | ---: | ---: | ---: | ---: |
| parent-only | $0.1101 | 42.0 s | 6 | 11 | 0 |
| compact Terra | $0.0957 (-13.1%) | 52.5 s (+24.9%) | 6 | 12 | 380 |
| compact Luna | $0.1093 (-0.8%) | 51.7 s (+23.2%) | 6 | 12 | 448 |

Terra cleared the cost requirement but exceeded the allowed 10% latency regression. Luna
missed both a material cost improvement and the latency boundary. Advertising the unused
delegate on simple prompts also retained the previously observed schema cost: median total
cost was about 6.5% higher than parent-only even with zero activations.

## Interpretation

Compact output and a cheaper child are insufficient when the parent still takes six model
rounds and performs the same authoritative tracing, mutation, and verification. In the
replication, each delegate added roughly one tool and exposed child latency without reducing
the median Sol round count. The favorable one-shot pilot was stochastic rather than a stable
harness improvement.

Any later delegation experiment needs a stronger structural change: replace a parent round
or a substantial authoritative read set, rather than merely making the child response
cheaper. It must again compare directly with parent-only and include child cost and latency.
