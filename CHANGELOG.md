# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-17

**The desk can write first.** Until now a case could only start with somebody
asking; now it can start with you, through the same seam and the same
algorithm.

### Added

- `agent.open_support_conversation_with!(requester, message, about:, topic:, files:, via:, desk:)` — write first, as the desk: the message is the desk's, signed by the agent, and it lands in the requester's inbox as the desk. The only agent-side verb in the gem, because it is the only action with no ticket yet.
- `SupportDesk::Ticket.open!(…, by: an_agent)` — the seam under it. `by:` defaults to the requester; an agent there is the desk writing first. A Symbol (`by: :system`) is refused with `NotAnAgent`: automation is deferred (docs 12, Q17).
- `opened_by` on every case — a polymorphic record, exactly like `closed_by` — with `opened_by_requester?` / `opened_by_support?` and the `opened_by_requester` / `opened_by_support` scopes, which partition the table.
- `config.opening_line` and `config.opening_line_from_support`: the system line a thread opens with, posted inside the opening transaction. A String (with `%{label}`, `%{desk}`, `%{reply_within}`), an I18n key, a block, or nil. The first defaults to nil; the second to the gem's own copy, because a message from a desk somebody never wrote to has to explain itself.
- `config.find_requester`: how a console turns something an agent typed into the person they meant. Without it the console accepts only a GlobalID from one of your own pages.
- `has_support_tickets if:` — who may ask, and who may be written to — with `support_requester?` and `support_desk` on the requester model.
- Console: `new` (the form) and `open_conversation` (the send) as collection actions, with the "Write to someone" door in the mounted console and the generated one. `SupportDesk::Console::COLLECTION_VERBS` is the table the router reads.
- Generators: `rails g support_desk:upgrade` copies the additive `opened_by` migration (the same file a fresh install runs), and `rake support_desk:backfill_opened_by` runs its backfill again after a deploy.
- `SupportDesk::NotARequester`, and `SupportDesk.humanize_duration` (moved off `Wizard`, which keeps a delegation).

### Changed

Behaviour changes, not refactors. Read them before upgrading:

- **System messages are never folded into the clocks.** They never reached the clocks through chats anyway; now a hand-written `register!` ignores them too, and so does a message from somebody who is neither the requester nor the desk. Neither moves `awaiting`, an SLA clock or the last-registered marker.
- **`first_agent_reply_at` is only set when a requester message came first.** An agent writing into a case with nothing in it is not answering anything, and an out-of-order replay whose requester clock is later is not evidence either.
- **`:agent_replied` is not emitted for the desk's own opening message** on a case the desk opened. An agent's first message into an old empty case the REQUESTER opened is still a reply, and still emits.
- **The asking limits count only requester-opened cases.** `open_rate_limit` and `max_open_tickets` limit asking, not being asked, so cases you opened no longer spend somebody's allowance.
- **Requester eligibility is checked at every message write.** `chat_locked?` is now "the requester can't be written to, or the case is closed on a desk that locks closed cases", re-read from the database rather than taken from a cached association. The thread, the queue row, the notes and the close are all unchanged; only new messages stop, and `actions_for` stops offering `:reply`.
- **`reply!` registers its message inside its own lock**, in a savepoint that owns the whole operation — so a caller who rescues its failure and commits their own transaction commits none of ours. `open!` does the same for opening and for the reply a reused case turns into.
- **The opening line is the gem's, and it is posted inside the opening transaction**, pinned one database tick above the message it introduces. Hosts that posted their own line after commit can delete that code.
- **`Console::ERROR_KEYS` is gone**, replaced by the error's own name (`NotTheAssignee` → `not_the_assignee`) with a generic fallback. Every key the table listed is a name it derives to, so a host that overrode one keeps its wording.
- `Console::TRANSITIONS` and `ConsoleRoutes::MEMBER_VERBS` are aliases of `Console::MEMBER_VERBS` for one release.
- `Chats::Error` is rescued into a console flash; `Chats::ConfigurationError` is deliberately not.

### Fixed

- `Ticket.open!` no longer reloads the case it just opened. The clocks are folded in on the same instance, inside the transaction, so the row that commits is already true.

### Upgrading from 0.1

1. `rails generate support_desk:upgrade` and **migrate before deploying 0.2 code** — the column is additive and nullable, so 0.1 keeps running against it.
2. Deploy 0.2. Once the old processes are gone, run `rake support_desk:backfill_opened_by` once: it points any case an old process opened in the meantime at its requester. It is idempotent, and `SupportDesk.doctor` tells you when it is needed.
3. Want the console door? Add `new` to your routes (`only: %i[index show new]`) and re-run `rails g support_desk:console` for the two new views, or copy them by hand if your console is customized.

Rolling back is a host code rollback, not a Gemfile pin: 0.1 does not know the new settings, routes or predicates. Keep the columns and the provenance already written — but note that 0.1's `Assignment#release!` revalidates `reason` and rejects `opened`, so closing, releasing or handing off a case the desk opened will fail under 0.1 until a compatibility patch accepts that reason. Prefer disabling the entry point (drop `new`/`open_conversation` from your routes) over downgrading with active desk-opened cases.

## [0.1.3] - 2026-09-17

### Fixed

- Opening a case and its first message is atomic; rejected uploads render validation errors with the draft preserved.
- Reopening historical cases preserves both conversations when a newer case already exists; new submissions still reuse an open case.
- Assignment authorizes its actor, and assignment, hand-off, release and reply policy check current state under the row lock.
- Delayed message registration derives whose turn it is from both clocks and cannot reopen a case closed after the message.
- Reading an authorized console transcript marks the desk's read horizon through the last displayed message.
- Topics resolve within their ticket's desk; wizard routing and response promises honor nondefault desks.
- The requester upload form uses multipart encoding, and its send budget is shared with chats.
- Requires chats >= 0.3.2, whose authors need no messaging capabilities of
  their own, so staff sign a desk reply without becoming messagers.

## [0.1.2] - 2026-09-16

### Fixed
- **0.1.1 shipped without the thing it was released for.** The gem published
  to rubygems as 0.1.1 was built from a tree that predated the merge, so
  `SupportDesk::Desk` never declared `verified: true` and no desk was ever
  badged — while the release notes said it was. The repository was correct
  the whole time; only the package was wrong, which is the worst shape for
  this kind of mistake because nothing in git looks off.

  `SupportDesk::Desk.chat_verified?` now returns true, and a test asserts it
  against the loaded class rather than the source file, so a package built
  from the wrong tree fails instead of shipping quietly.

## [0.1.1] - 2026-09-16

### Changed

- **The desk is an official account.** `SupportDesk::Desk` now declares
  `acts_as_messager verified: true` (chats 0.3.0), so chats badges it
  wherever it names a messager: the grouped inbox row and the case thread's
  header. A requester can tell the real desk from anyone who simply called
  themselves "Soporte" without reading the name carefully — which matters
  more here than anywhere else in a product, because the desk is the one
  counterpart that legitimately asks people for account details. The badge
  is chats' own; recolour it with the `--chats-verified` CSS variable or
  replace it with `Chats.configure { |c| c.verified_badge = … }`.
- **The inbox door is badged too.** The door that stands in for the desk's
  inbox row before a requester has written now carries the same mark, so the
  badge reads as a property of the account rather than of having already
  written to us. It still never INSERTs a desk (`support_desk_record` is a
  find-or-stand-in, never `SupportDesk.desk`, whose first call in a process
  creates the row), and it costs no query of its own: the door's avatar and
  its badge share one memoised lookup per render, pinned by a query-count
  test.

## [0.1.0] - 2026-09-16

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
- **`SupportDesk::Wizard`** — the three-step "what do you need help with?"
  machine as a PORO, so the views are replaceable and a native app or an API
  can drive the same steps. Subjects travel as signed GlobalIDs and are
  re-checked against `supportable_by?` anyway.
- **A requester-facing engine you just mount.** `mount SupportDesk::Engine
  => "/support"` and the user side is done: their list of cases (open ones
  as chats rows, closed ones folded away), the three wizard frames at one
  URL, and a stable `/support/tickets/:id` that redirects into the
  conversation. Every step is a real URL, so the back gesture, a bookmark
  and a cold-boot deep link all work; `data-turbo-action="advance"` is what
  lets them also re-render in place. Limits (`max_open_tickets`,
  `open_rate_limit`) render a wall with the cases they already have listed
  on it, never a 500.
- **`link_to_support(about:, text:, **html)` and `support_unread_badge`.**
  The door renders nothing for a record that is not supportable or not
  theirs, so it is safe in shared partials, and leads to the conversation
  they already have rather than opening a second one.
- **Two rows on chats’ own screens**, through its view slots: the
  "¿Necesitas ayuda? Escríbenos" door above the inbox for somebody who has
  never written (`config.inbox_entry`), and a way out of a case closed on a
  desk configured `closed_tickets: :locked`.
- **`SupportDesk.native_path_rules(mount:, title:)`** — the Hotwire Native
  path-configuration rules for both surfaces, as pushed screens.
- **`config.authenticate_method`** so the engine runs the host’s own
  authentication filter, and `rails g support_desk:views` to eject every
  requester-facing template.
- **Queues and presenters**
 — `Queue#counts` in one grouped query, a badge
  cached 30s per agent, `ContextCard`, `Summary`, `Timeline` and
  `actions_for(agent)`, all with no view dependency.
- **The agent console, in three layers** — the query objects above, then a
  routing concern and a controller concern, then a generator. The generated
  madmin console and the turnkey `SupportDesk::ConsoleEngine` use nothing
  the concerns don't expose, which is what makes "bring your own UI" a
  promise rather than a hope.
  - `concerns: :support_console` in any route set draws member `reply`,
    `take`, `assign`, `hand_off`, `release`, `close`, `reopen`, `note` and
    `change_topic`, plus collection `next`.
  - `SupportDesk::Console` scopes everything it reaches through
    `config.visible_desks_for` — the ticket, the queue, the tab counts, the
    badge and `next`, with `?desk=` able to name only a desk already on that
    list. A case on a desk you may not work is a **404**; no desks at all is
    a **403**. It asks `config.authorize_console` before every action (a
    hook that raises denies, and is reported through `Rails.error`), checks
    `actions_for` so it never accepts a verb it wouldn't have offered, sets
    `SupportDesk::Current.actor`, and turns every domain refusal into a
    translated flash — a policy never 500s.
    `SupportDesk::Console::Index` is the optional `@queue` / `@scope` /
    `@tickets`, preloading everything a row renders including the subject.
  - `rails g support_desk:console madmin` writes a host-owned controller, a
    madmin resource, and the view set: queue tabs, waiting chips coloured by
    `at_risk_after` / `reply_within`, context card, transcript, timeline,
    a "Reply"/"Internal note" composer, the hand-off picker, and a nav badge.
    Idempotent, `--force` to take new defaults.
  - `mount SupportDesk::ConsoleEngine => "/admin/support"` for hosts with no
    admin framework, rendering those same views through
    `config.console_parent_controller`.
- **Events out, policy in.** `SupportDesk.on(:ticket_opened) { … }`,
  multi-subscriber, isolated with `Rails.error.report`, mirrored on
  `ActiveSupport::Notifications`.
- **Multi-desk configuration** where every desk inherits what it doesn't
  state, with setters that validate on assignment and boot-time
  `ConfigurationError`s that carry the fix. `config.visible_desks_for` and
  `config.authorize_console` are the console's two hooks into it.
- **`SupportDesk.doctor`** — configuration, the chats seams, and the data
  invariants, with an `ok?` for CI.
- **`SupportDesk::TestHelpers`** for host suites.
- Install generator (migration + annotated initializer), Spanish and
  English locales, and a mountable engine.

### Notes

- **The desk registers itself with chats at boot.** `acts_as_messager`
  registers a class when it loads, and `Chats::Inbox` folds support threads
  into one row only for registered grouped messagers, so under lazy
  autoloading the inbox showed every support conversation as its own row
  until something happened to reference `SupportDesk::Desk`. The engine's
  `to_prepare` now touches the desk the way it already touches the helper
  (#2). Eager-loading production hosts never saw it; development did.
- **`jsonb` on PostGIS.** The install migration decides jsonb-or-json by
  adapter name, and activerecord-postgis-adapter answers `"PostGIS"`, not
  `"PostgreSQL"` — the first cut matched the full word and silently gave
  PostGIS hosts plain `json` columns. Caught while integrating with a PostGIS host, before
  the gem shipped; the template now matches the prefix (`/\Apostg/i`).
- `SupportDesk::OffDuty` is NOT part of 0.1.0. Duty is a seam this release
  only asks about (`agent.on_duty?` decides who is notified and what
  `actions_for` offers); nothing in it assigns work, so nothing can
  honestly refuse on those grounds yet. It arrives with the duty table in
  0.3. `SupportDesk::Locked` IS raised — writing into a closed ticket on a
  desk configured `closed_tickets: :locked` — and subclasses
  `InvalidTransition`, so either name catches it.

### Credits

The wizard copy, the console screens and the Spanish strings began life in
carhey#309, and were lifted into the gem with the author's blessing.
