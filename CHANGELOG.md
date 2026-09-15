# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased

First release: the whole core of a support desk, on top of `chats` 0.2.

### Added

- **Tickets that are conversations.** `SupportDesk::Ticket` is a case with
  exactly one `Chats::Conversation` behind it. Transitions (`reply!`,
  `note!`, `assign!`, `hand_off!`, `release!`, `close!`, `reopen!`,
  `change_topic!`, `attach_subject!`) each take `by:`, run under the
  ticket's row lock, write one append-only event row, and emit after the
  transaction commits. Repeating one that already happened returns `self`
  and writes nothing; one that can't happen from here raises
  `SupportDesk::InvalidTransition`.
- **Three macros.** `has_support_tickets` adds exactly four methods to
  whoever asks for help; `supportable topic: :order` makes a domain record
  something to ask about, with a working default for every method;
  `acts_as_support_agent if: :admin?` makes someone able to answer, and
  adds no verbs — the ticket is the subject of every sentence.
- **Topics as a tree of value objects.** Defined in code, frozen at boot,
  stored on the ticket as a stable path (`"billing/invoice"`).
  `ticket.topic` is a `SupportDesk::Topic`, not a string, and a path no tree
  knows reads as a null object that still renders.
- **Assignment as a history.** Who held the case, when, why they stopped,
  with `ticket.assignee` as the denormalised pointer to the one open row.
  Reopening gives the case back to whoever handled it.
- **`awaiting` and the SLA clocks**, maintained by a single subscriber to
  chats' `:message_created` and idempotent on the message id — so a message
  typed in the app, mirrored in by email or posted by a bot all move the
  same clock, and a redelivered event never double-counts.
- **Reply policies**: `:anyone` (the first agent to answer an unheld ticket
  takes it; a drop-in on someone else's is recorded), `:take_over`,
  `:assignee_only`.
- **Queues and presenters** — `Queue#counts` in one grouped query, a badge
  cached 30s per agent, `ContextCard`, `Summary`, `Timeline` and
  `actions_for(agent)`, all with no view dependency.
- **Events out, policy in.** `SupportDesk.on(:ticket_opened) { … }`,
  multi-subscriber, isolated with `Rails.error.report`, mirrored on
  `ActiveSupport::Notifications`.
- **Multi-desk configuration** where every desk inherits what it doesn't
  state, with setters that validate on assignment and boot-time
  `ConfigurationError`s that carry the fix.
- **`SupportDesk.doctor`** — configuration, the chats seams, and the data
  invariants, with an `ok?` for CI.
- **`SupportDesk::TestHelper`** for host suites.
- Install generator (migration + annotated initializer), Spanish and
  English locales, and a mountable engine.

### Credits

The wizard copy, the console screens and the Spanish strings began life in
carhey#309, and were lifted into the gem with the author's blessing.
