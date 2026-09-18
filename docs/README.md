# support_desk — internal planning documents

These are local planning/review documents, not the public README or a claim
that proposed functionality exists. The assistants documents are tracked on
the local docs/assistants-prd branch; historical planning documents may exist
only in another local checkout. Nothing here authorizes publication of
host-specific material to the public repository.

## Current assistants work (2026-09-18)

| Document | Role |
|---|---|
| [12 — owner decisions](12-open-questions.md) | Preserved choices #19–22 and explicitly labeled review refinements |
| [14 — design record](14-assistants.md) | Responsibility boundary and reasons for the proposed shape |
| [15 — implementation contract](15-assistants-prd.md) | Normative API/state/transaction/schema/UI/host/release requirements |
| [15 — adversarial review](15-assistants-review.md) | Findings against d9ff5c5, source evidence, corrections and required verification |

For assistants, the revised 15 contract wins over earlier Bot/Responder,
turn-token, migration and stale-draft sketches. Those originals remain in
commit d9ff5c5. Source code and actual released tests remain the truth about
what is implemented today. No assistant feature was implemented by this review.

## Historical planning set

The earlier 00–13 documents cover initial decisions, DX, domain model, topics,
agents/routing, channels, console, requester UI, Chats seams, events,
security/privacy, roadmap and writing-first. Their old “current state”
statements (available gem names, unreleased versions, zero production tickets)
are dated historical context, not assertions about the present system.

Use the public root README and current source for installed APIs. Before a
release, inspect the built gem manifest: support_desk.gemspec explicitly
excludes docs/, even when force-added on a documentation branch. Git ignore
alone would not exclude a tracked planning file from a public git push.
