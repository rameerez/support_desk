# `support_desk` — internal planning docs

**Status:** pre-code design, 2026-09-15. Written after the adversarial review of
carhey#309 ("Soporte in-app con los admins"), which incubated this domain inside
CarHey on top of the `chats` gem. These docs are gitignored and stay that way:
they carry host-specific detail that has no business in a gem repo, and the
implementation supersedes them. They are the working plan, not the README.

**One sentence:** `support_desk` is customer support for any Rails app —
tickets that are conversations — built as a *product gem* on the `chats`
*kernel gem*, the way `usage_credits` is built on `wallets`.

## Reading order

**Start with [PRD.md](PRD.md)** — the single source of truth: final API (§4), the chats 0.2.0 checklist (§5), the carhey#309 rework (§7), acceptance gates (§8). The numbered docs below are the detail it references; where they disagree with the PRD, the PRD wins.

| # | Doc | What it settles |
|---|-----|-----------------|
| 00 | [decisions.md](00-decisions.md) | The load-bearing domain decisions and why. Read first. |
| 01 | [dx-api.md](01-dx-api.md) | Draft of the host-facing API. **Superseded by PRD §4** (kept for the reasoning; names were bulk-updated). |
| 02 | [domain-model.md](02-domain-model.md) | Tables, state machines, invariants, indexes, concurrency. |
| 03 | [topics.md](03-topics.md) | Topic trees, pickers, prefill, "other", retirement, DB-backed future. |
| 04 | [agents-and-routing.md](04-agents-and-routing.md) | Humans, AI, external agents. Assignment history, hand-offs, drop-ins, shifts, routing, escalation, AI disclosure. |
| 05 | [channels.md](05-channels.md) | Substrates ("channels"): chats as the canonical transcript, email (Action Mailbox, Stripe-style mirror), Intercom import, guest requesters. |
| 06 | [admin-api.md](06-admin-api.md) | BYOUI: queue objects, presenters, the console controller concern, routing concern, generators for madmin, realtime, metrics. |
| 07 | [user-ui.md](07-user-ui.md) | End-user engine: inbox stack, wizard, doors, closed state, native path rules, ejectable views. |
| 08 | [chats-seams.md](08-chats-seams.md) | Everything `chats` 0.2.0 must gain first, with API and migration sketches. |
| 09 | [events-and-notifications.md](09-events-and-notifications.md) | Event catalogue, subscribers, Noticed wiring, PII defaults. |
| 10 | [security-privacy-compliance.md](10-security-privacy-compliance.md) | Authorization, reply tokens, PII, retention, GDPR export, audit. |
| 11 | [roadmap.md](11-roadmap.md) | Releases 0.1 → 1.0, CarHey acceptance criteria, migration of #309. |
| 12 | [open-questions.md](12-open-questions.md) | What only the owner can decide. |
| 14 | [assistants.md](14-assistants.md) | AI agents as first-class citizens: `SupportDesk::Assistant`, autonomy levels, drafts + human review, the turn token, `escalate!` / `request_human!`, brief + transcript. Design only, not implemented (2026-09-18). |
| 15 | [assistants-prd.md](15-assistants-prd.md) | **The implementation contract for 14 (v3)**: full API, algorithms under lock, migration, surfaces, locales, harness contract + generator, test plan, CHANGELOG, delivery, CarHey "Rose" rollout, edge-case register. Not implemented (2026-09-18). |
| 15r | [assistants-review-1.md](15-assistants-review-1.md) · [assistants-review-2.md](15-assistants-review-2.md) | The adversarial review of v1 (46 findings) and the disposition of each in v3. |

## Ecosystem context (facts, verified 2026-09-15)

- Three composition styles exist among rameerez gems: **kernel + product with a
  hard dependency** (`usage_credits` → `wallets ~> 0.3`, subclassing
  `Wallets::WalletBase`, sharing `Wallets::CallbackDispatcher`), **hard
  dependency with service delegation** (`footprinted` → `trackdown`), and
  **duck-typed contract without dependency** (`chats` implements
  `Moderate::Reportable`). Composable gems are a principle of the ecosystem.
- `chats` is 0.1.1 on rubygems; its PRD excludes ticketing on purpose and lists
  "support agents" as legitimate messagers.
- Gem names: `support_desk` and `supportdesk` are free on rubygems; `support`,
  `helpdesk`, `desk`, `tickets`, `servicedesk` are taken.
- CarHey production has **zero** support tickets today (#309 is an unmerged
  draft). Schema changes are free right now and expensive later.
