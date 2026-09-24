# 🎫 `support_desk` - Customer support for your Rails app, as conversations — answered by your team and by AI agents on a leash

[![Gem Version](https://badge.fury.io/rb/support_desk.svg)](https://badge.fury.io/rb/support_desk) [![Build Status](https://github.com/rameerez/support_desk/workflows/Tests/badge.svg)](https://github.com/rameerez/support_desk/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=support_desk)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=support_desk)!

`support_desk` gives your Rails app a **support desk**: tickets that are real conversations. Somebody asks for help about something in your app (a ride, an order, a withdrawal) or about nothing in particular, your desk answers, humans sign the answers, and your team works a queue.

**AI agents are first-class citizens of that desk.** An assistant is an agent with a policy: a seat, a name, a turn budget and a level (`observe · draft · reply · resolve`) that says what she may *produce* on a case. At the default level she proposes and a person sends, signed by them; raise her level per topic and she answers customers herself, hands off when she is unsure, and can never touch a case a human holds, a money topic you capped, or a customer who asked for a person. The gem ships the guardrails — policy, drafts and review, the turn that makes a late model answer harmless, disclosure, the two exits, the sweep that catches a dead harness — and **no LLM**: bring any provider, any prompt, any retrieval, in a job of about ten lines. [→ Assistants](#-assistants)

Here is the whole thing — the kind of support desk a DoorDash, an Uber Eats or a Grab needs — running on a made-up delivery app called Pepperbox. These are the **bundled views**, unmodified, themed by the host with a handful of CSS variables:

| One row, every case | Pick a topic | Which order? |
|:---:|:---:|:---:|
| ![The chats inbox: every support conversation folded into one official, verified row](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/01-inbox.png) | ![The wizard's first step: a list of support topics](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/02-topics.png) | ![The wizard's second step: the requester's own orders](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/03-subject.png) |
| **Say what happened** | **Signed by a human** | **The agent queue** |
| ![The composer, with a card naming the order the case is about](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/04-compose.png) | ![The conversation, with the desk's verified badge and an answer signed by the agent who wrote it](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/05-thread.png) | ![The agent queue, with tabs, counts and waiting chips](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/06-queue.png) |
| **The whole case** | **Notes stay inside** | **Hand it over** |
| ![One case: what it is about, and the transcript the requester sees](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/07-case.png) | ![The internal note composer, which never reaches the customer](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/08-note.png) | ![Handing a case to a colleague, above the history of every hand-off before it](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/09-handoff.png) |

It is a product gem on the [`chats`](https://github.com/rameerez/chats) kernel: chats owns the transcript, realtime, attachments, read state and moderation; `support_desk` owns the case — topics, assignment, SLA clocks, events and the console API.

Every app eventually needs a support inbox, and everyone rebuilds the same ticket table, the same "assigned to me" tab, the same "which order is this about?" picker and the same email bridge — and, lately, the same "let the model answer, but not *that*" rules. `support_desk` is that whole rebuild, done once, done right, on top of the messaging you already have.

What "AI-native" means here, concretely:

- **One verb for the harness.** `ticket.respond!(text, by: rose, turn:)` — policy decides whether it is sent, drafted for a person, or withheld with the reason on the record. The job never encodes the rules.
- **Bounded authority, in the model.** Levels, topic caps, a per-case cap, pause, and floors for closed / human-held / human-requested cases — enforced inside every transition, not in a prompt or a button.
- **A turn, not a lock-free hope.** Every message and transition moves `assistant_turn`; every assistant action requires and consumes it, so a late, retried or redelivered job writes nothing.
- **Human in the loop by default.** Proposals a person sends verbatim or edited — as *their* message — or rejects with a reason you can raise her level on.
- **Two exits, always.** She escalates; the customer has a door to a person that never disappears.
- **Disclosure is your explicit choice**, and the record tells the truth in every mode.
- **Context as data.** `ticket.brief` and `ticket.transcript` — facts, roles, `may` / `may_not` — for any provider.

**Contents:** [Example](#-example) · [Quickstart](#quickstart) · [Configuration reference](#configuration-reference) · [Topics](#topics) · [Model macros](#the-model-macros) · [Tickets](#tickets) · [Queues and presenters](#queues-and-presenters) · [The requester experience](#the-requester-experience) · [The agent console](#the-agent-console) · [Writing first](#writing-first) · [Assistants](#-assistants) · [The wizard](#the-wizard) · [Events](#events) · [Errors](#errors) · [Locales](#locales) · [Doctor](#doctor) · [Compatibility](#compatibility) · [Testing](#testing) · [Module-level API](#module-level-api)

## 👨‍💻 Example

`support_desk` reads like plain English:

```ruby
class User < ApplicationRecord
  acts_as_messager                    # chats
  has_support_tickets                 # can ask for help
  acts_as_support_agent if: :admin?   # can answer
end

class Order < ApplicationRecord
  supportable topic: :order           # can be asked about
end

ticket = alice.ask_support!("My order never arrived", about: order)   # she asks
ticket.assign!(to: lucia, by: lucia)
ticket.reply!("We're on it", by: lucia)                               # you answer
ticket.close!(by: lucia)

lucia.open_support_conversation_with!(alice, "We saw your refund bounced", about: order)   # you write first

config.assistant(:rose) { |rose| rose.autonomy = :draft; rose.disclosure = :signature }  # an AI agent, on a leash
rose = SupportDesk.assistant(:rose)
ticket.respond!(answer_from_your_model, by: rose, turn: ticket.assistant_turn)         # she proposes; policy decides
ticket.pending_draft.send!(by: lucia, seen_turn: ticket.assistant_turn)                # a person sends it, signed by them
```

That's a ticket, a conversation, an assignment history, an append-only audit trail, an AI agent whose every action is policy-checked under the row lock, and a dozen events your app can subscribe to.

## Quickstart

Add the gem:

```ruby
gem "support_desk"
```

Install it (creates the migrations + an annotated initializer):

```bash
bundle install
rails generate support_desk:install
rails db:migrate
```

Already on 0.1? `rails generate support_desk:upgrade` copies only the
migrations a version bump needs (0.2.0: who opened each case) and nothing
you own. Migrate first, pause support traffic, drain all old web requests and
workers, and backfill before starting 0.2 traffic. This is not a rolling
upgrade: old assignment writers cannot handle new support-opened cases.
See the CHANGELOG for the complete cutover and rollback procedure.

Already on 0.2? The same generator copies the 0.3 assistants migration,
which is additive and needs no drain — see [Assistants](#-assistants).

Three model lines and one route line:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  acts_as_messager
  has_support_tickets
  acts_as_support_agent if: :admin?
end

# app/models/order.rb
class Order < ApplicationRecord
  supportable topic: :order
end

# config/routes.rb
mount SupportDesk::Engine => "/support"
```

Tell the desk who it is:

```ruby
# config/initializers/support_desk.rb
SupportDesk.configure do |config|
  config.name = "Support"
  config.agents { User.where(admin: true) }

  config.topics do
    topic :order, about: Order
    topic :billing do
      topic :invoice, about: Invoice
    end
    other
  end
end
```

Check your work any time with `SupportDesk.doctor.print`.

Desk records are memoised for the life of the process, so anything that has to change everywhere at once belongs in this initializer rather than in a desk's `settings` column.

## Configuration reference

Everything lives in `config/initializers/support_desk.rb` (the install
generator writes an annotated one). Two rules, shared with the rest of the
gem ecosystem: class names are stored as **strings** and constantized lazily,
so the initializer can name app classes before they load and everything
survives reloads; and every setter **validates on assignment** and raises
`SupportDesk::ConfigurationError` with the fix in the message — a
configuration mistake is a boot failure, never a 3 a.m. `NoMethodError`.

### Installation settings

| setting | default | what it decides |
|---|---|---|
| `requester_class` | `"User"` | the model with `has_support_tickets`; it must also be a chats messager |
| `parent_controller` | `"::ApplicationController"` | what the requester-facing engine inherits: your layout, auth, helpers, locale |
| `console_parent_controller` | your admin's base controller | what the mounted `ConsoleEngine` and the generated console inherit |
| `current_requester_method` | `:current_user` | how the engine finds the person asking |
| `current_agent_method` | `:current_user` | how the console finds the person answering (or define `current_agent` in your controller) |
| `authenticate_method` | `:authenticate_user!` | your own filter, run before every requester screen |
| `visible_desks_for` | `nil` (every desk) | `->(agent) { … }` returning the desks this agent may work; scopes the whole console |
| `authorize_console` | `nil` (allow) | `->(agent, ticket, action) { … }`; asked before every console action, `ticket` is nil for `index`, `new`, `next` and `open_conversation`; a hook that raises **denies** |
| `assistant(key) { … }` | — | declare an assistant (see [Assistants](#-assistants)); `config.assistants`, `config.assistant?(key)` read them back |
| `default_assistant` | the only one declared | which assistant the `:default` desk gets when more than one exists |
| `on(event) { … }` | — | subscribe to an event (see [Events](#events)); pass `key:` from code that reloads |

### Desk settings

Top-level setters configure the `:default` desk. Every other desk inherits
whatever it does not state:

```ruby
config.desk :billing do |desk|
  desk.name = "Billing"
  desk.reply_within = 8.hours
  desk.topics { topic :invoice, about: Invoice; other }
end

SupportDesk.desk            # the :default Desk record, memoised for the process
SupportDesk.desk(:billing)  # another one (nil if nobody configured it)
```

| setting | default | values / meaning |
|---|---|---|
| `name` | the key, humanized | what requesters see as the counterpart |
| `avatar` | `nil` | anything `image_tag` takes, or `->(desk) { … }` |
| `email` | `nil` | the address the email channel will answer from (channel lands in a later release) |
| `agents { … }` | — | a block or lambda returning the agent pool: notified while a case is unheld, offered in the assign picker |
| `assistant` | the default one | the key of the assistant that works this desk; an explicit `nil` **disables** her here rather than inheriting (see [Assistants](#-assistants)) |
| `topics do … end` | `other` only | the topic tree (see [Topics](#topics)) |
| `reply_policy` | `:anyone` | `:anyone` (a drop-in posts, signed; an unheld case is taken by whoever answers) · `:take_over` (replying reassigns) · `:assignee_only` (raises `NotAllowed`) |
| `announce_assignments` | `:first_only` | `:first_only` ("Lucía is taking care of your request" once) · `:always` (hand-offs too) · `:never` |
| `closed_tickets` | `:reopen_on_reply` | `:reopen_on_reply` (a requester writing reopens the case) · `:locked` (composer replaced by a notice) |
| `reply_within` | `24.hours` | the SLA breach threshold **and** the promise the requester reads |
| `at_risk_after` | `4.hours` | when a waiting case starts showing as at risk |
| `open_rate_limit` | `{ to: 5, within: 1.hour }` | how often one requester may **ask**; `nil` disables. Counts only cases the requester opened |
| `max_open_tickets` | `5` | how many cases one requester may have open; `nil` disables. Same rule |
| `inbox_entry` | `:always` | when the desk shows in an inbox with no cases yet: `:always` · `:when_tickets` · `:never` |
| `routing` | `:manual` | new cases are unassigned and the first "take" wins (`:round_robin` / `:least_loaded` are reserved and refused until they ship) |
| `mirror_replies_by_email` | `:when_away` | reserved for the email channel: `:always` · `:when_away` · `:never` |
| `auto_close_after` | `nil` | reserved for the sweep job: a duration after which an answered case closes itself |
| `opening_line` | `nil` | the system line a requester-opened thread starts with (see [Writing first](#writing-first)) |
| `opening_line_from_support` | the gem's I18n copy | the same line for a case the desk opened |
| `find_requester { \|query\| … }` | `nil` | how a console turns what an agent typed into a requester record |

`SupportDesk.doctor.print` checks all of it against a running app (see
[Doctor](#doctor)).

## Topics

Topics are a **tree defined in code** and stored on the ticket as a stable
path (`"billing/invoice"`), so they can carry behaviour — which models they
attach to, which picker, which desk — and be reviewed and versioned like
everything else. Labels are I18n keys by default, so copy is a locale edit.

```ruby
config.topics do
  topic :order,   about: Order, subject: :required, icon: "package"
  topic :billing, priority: :high do
    topic :invoice, about: Invoice, ask: "Which invoice?"
    topic :refund,  prefill: "Hi, I'd like a refund for ", desk: :billing
  end
  topic :beta,    only: ->(requester) { requester.beta? }
  topic :legacy,  retired: true                 # old cases keep their label; nobody can open a new one
  other                                         # the free-form leaf every desk should have
end
```

| option | meaning |
|---|---|
| `about:` | the `supportable` class(es) this topic is about; the wizard offers the requester's own records |
| `subject:` | `:required` (must pick one) · `:optional` (offers "none of these") · `:none` (free-form) |
| `candidates:` | `->(requester) { … }` overriding which records the picker shows |
| `ask:`, `placeholder:`, `prefill:`, `label:` | copy, when you'd rather not use the locale keys; `prefill:` may be a `->(subject) { … }` |
| `only:` | `->(requester) { … }` — who is offered this topic in the wizard (agents may still file onto it) |
| `priority:` | `:normal` · `:high` · `:urgent` — sorts the queue |
| `desk:` / `route_to:` | send cases on this topic to another desk |
| `retired:` | hidden from the wizard, still readable on old cases |
| `icon:` | a key your views may render; the gem never does |
| `assistant:` | the most an assistant may produce on this branch (see [Assistants](#-assistants)) |

`about`, `candidates`, `desk`, `route_to`, `priority`, `only` and `retired`
are inherited down the branch; copy never is. `assistant:` is the one option
that is neither inherited nor overridden: `Topic#assistant_cap` is the
**minimum** over the node and every ancestor, so a child can only tighten
what a parent allowed. Labels come from
`support_desk.topics.<path>.label` in your locale files (`ask` and `hint`
alongside).

```ruby
ticket.topic                    # a SupportDesk::Topic value object
ticket.topic.path               # "billing/invoice"
ticket.topic.label              # "Invoice"
ticket.topic.full_label         # "Billing › Invoice"
ticket.topic.under?(:billing)   # true
ticket.topic.free_form?  .subject_required?  .retired?  .priority  .about  .icon  .assistant_cap
SupportDesk.find_topic("billing/invoice")   # across every desk; nil, never a raise
```

Agents can refile a case (`ticket.change_topic!(to: "billing/refund", by:)`)
and point a free-form one at the record it turned out to be about
(`ticket.attach_subject!(order, by:)`); both are events.

## The model macros

### `has_support_tickets(desk: :default, as: nil, if: nil)`

Adds six methods to whoever asks for help:

| method | what it does |
|---|---|
| `support_tickets` | `has_many`, newest first. Chain the scopes: `alice.support_tickets.open.about(order)` |
| `ask_support!(message, about:, topic:, files:, via:)` | opens the ticket, posts the first message, emits `ticket_opened`, and hands back the `Ticket` — or the open one they already have about the same thing |
| `support_requester?` | may this person ask for help, and be written to, right now? |
| `support_desk` | the desk record their tickets go to |
| `awaiting_support_reply?` | is the desk holding any of their questions? |
| `unread_support_count` | for a nav badge, counted against the chats read horizon |

`if:` is a method name or a callable, and it is a **write** rule rather than a screen rule. `has_support_tickets if: :kept?` means a closed account can neither ask nor be written to, on every path — while its history stays readable, its cases stay in the queue, and agents can still take notes on them and close them.

### `supportable(topic:, candidates: nil, one_open_ticket: true)`

Makes a domain record something people can ask about. Every method has a working default; override the ones that matter:

| method | default |
|---|---|
| `support_label` | `"Order 42"` — the ticket's label and the card's title |
| `support_status` | `nil` — a status pill under the label |
| `support_context` | `{}` — key/value pairs agents see in the console |
| `support_url` | `nil` — "open in admin" |
| `supportable_by?(requester)` | `user == requester` |
| `.support_candidates_for(requester)` | the requester's own association, for the "which one?" picker |

### `acts_as_support_agent(if: nil, kind: :human)`

Makes someone able to answer. Agents are never chats participants — the desk sends, the agent *authors* — so this needs no messaging setup at all. It adds `support_agent?`, `support_agent_name`, `support_agent_avatar`, `on_duty?`, `support_capacity`, `support_queue` and exactly one verb — `open_support_conversation_with!`, the only agent action with no ticket yet (see [Writing first](#writing-first)). Everywhere else the ticket is the subject of the sentence.

`kind:` is `:human` or `:ai`, and anything else is a boot failure. Declaring one of your own models `kind: :ai` does **not** hand it an agent's authority: every support write by it, or to it, is refused with `SupportDesk::NotAnAssistant`, and `doctor` warns about it. The only machine that may act on a case is the desk's own `SupportDesk::Assistant` — see [Assistants](#-assistants).

## Tickets

```ruby
ticket.reference        # "T-AB12CD", for email subjects and phone calls
ticket.label            # "Order SO1"
ticket.topic            # a Topic value object: .label, .path, .under?(:billing)
ticket.subject          # the Order (or nil)
ticket.status           # "open" | "snoozed" | "closed"
ticket.awaiting_reply?  # does the desk owe the next word?
ticket.waiting_for      # a Duration
ticket.overdue?  ticket.at_risk?
ticket.time_to_first_reply  ticket.time_to_close

ticket.reply!("…", by: lucia)               # sent by the desk, signed by Lucía
ticket.note!("VIP customer", by: lucia)     # internal; never in the conversation
ticket.assign!(to: lucia, by: lucia)        # "take"
ticket.hand_off!(to: pedro, note: "…", by: lucia)
ticket.release!(by: lucia, reason: :shift_end)
ticket.close!(by: lucia)  ticket.reopen!(by: alice)
ticket.change_topic!(to: "billing/invoice", by: lucia)
ticket.attach_subject!(order, by: lucia)
```

Every transition takes `by:` (falling back to `SupportDesk::Current.actor`), runs under the ticket's row lock, writes exactly one event row, and emits its events after the transaction commits. Repeating one that already happened returns `self` and writes nothing.

More of what a ticket knows:

```ruby
ticket.opened_by  ticket.opened_by_requester?  ticket.opened_by_support?   # who wrote first
ticket.opened_via          # :in_app | :email | :intercom | :api
ticket.channels            # every channel the case can be answered through
ticket.channels_summary    # "in app · email", in the reader's language
ticket.requester  ticket.assignee  ticket.desk  ticket.conversation  ticket.messages
ticket.assigned_to?(lucia)  ticket.about?(order)  ticket.reopened?  ticket.unassigned?
ticket.assignments         # the history of who held it; .open for the current seat
ticket.assignment_history  # the same, oldest first
ticket.events  ticket.notes                     # the append-only timeline, and just the internal notes
ticket.waiting_since  ticket.first_agent_reply_at  ticket.last_requester_message_at  ticket.last_agent_message_at
ticket.export              # a GDPR-friendly Hash: the requester's transcript and the events they saw, never notes
ticket.notification_title  # "Support · new message" — safe for a lock screen
ticket.notification_body   # the label — for an authenticated feed
ticket.register!(message)  # fold a chats message into the clocks by hand (imports); idempotent, and what the chats subscriber calls
ticket.desk_config         # this desk's slice of the configuration

SupportDesk::Ticket.find_by_reference!("t-ab12cd")      # forgives case, the prefix and Crockford lookalikes (O→0, I/L→1)
SupportDesk::Ticket.for_conversation(conversation)     # the case behind a chats conversation, or nil
SupportDesk::Current.actor = lucia                     # the fallback for every `by:` (the console sets it per request)
```

An **assignment** row records `agent`, `assigned_by`, `reason` (`taken`
`assigned` `handed_off` `routed` `drop_in_takeover` `escalated` `reopened`
`opened`), `note`, `assigned_at`, `released_at` and `release_reason`
(`handed_off` `released` `shift_end` `closed` `escalated`). An **event** row
has a `kind` (`opened` `assigned` `handed_off` `released` `drop_in` `closed`
`reopened` `topic_changed` `subject_attached` `note` `escalated`
`human_requested` `assistant_paused` `assistant_resumed` `draft_sent`
`draft_rejected` `assistant_withheld` — plus kinds reserved for later
releases), an `actor` and a `payload`, and is read-only once written.

### Scopes

```ruby
SupportDesk::Ticket
  .open .closed .not_closed .assigned .unassigned .assigned_to(lucia)
  .awaiting_reply .awaiting_requester
  .opened_by_requester .opened_by_support
  .waiting_over(4.hours) .at_risk .overdue
  .about(order) .about_any(Order) .on_topic(:billing)
  .for_desk(:billing) .opened_via(:email) .opened_between(range) .closed_between(range)
  .most_urgent_first .recent_activity_first .newest_first .oldest_first
  .find_by_reference("T-AB12CD")
```

## Queues and presenters

Bring your own UI on the agent side. Everything the console needs is plain Ruby:

```ruby
q = lucia.support_queue
q.mine  q.unassigned  q.awaiting  q.open  q.closed  q.needs_human   # relations
q.counts        # { awaiting: 4, mine: 2, … } in ONE query
q.badge         # the nav number, cached 30s per agent
q.next          # the most urgent thing this agent could pick up
q.tabs          # [[:awaiting, "Needs a reply", 4], …]
q.visible_tabs  # which ones this desk has any use for

ticket.context_card      # title, status, the host's own context pairs, the requester
ticket.summary           # one line for a list row, Slack, or a digest
ticket.timeline          # messages ⨉ events merged by time; .print in a console
ticket.actions_for(lucia) # exactly the buttons to render
```

```ruby
card = ticket.context_card
card.title  card.status  card.pairs  card.subject_url  card.topic_label
card.requester_name  card.requester_avatar  card.requester_since  card.requester_open_tickets
card.opened_by_label      # "Support · Lucía G." for a case the desk opened; "not recorded" for a 0.1 row awaiting backfill
card.to_h

ticket.summary.to_s       # "T-AB12CD · Order SO1 · Alice · awaiting reply (12 minutes)"
ticket.summary.state      # "awaiting reply" | "awaiting requester" | "closed" | "open", translated
ticket.timeline.entries   # Timeline::Entry: .kind (:message or the event kind), .at, .actor, .body
ticket.timeline.print     # in a console
```

## The requester experience

Mounting the engine is the whole user side: four screens, ejectable views,
and two helpers you drop anywhere in your app.

```ruby
mount SupportDesk::Engine => "/support"   # CarHey mounts it at "/messages/support"
```

| route | what |
|---|---|
| `GET /support` | their cases — open ones as chats rows, closed ones folded away, and the door into a new one |
| `GET /support/new` | the wizard: pick a topic, pick the thing, write. One URL, three Turbo frames |
| `POST /support/tickets` | `ask_support!`, then straight into the conversation |
| `GET /support/tickets/:id` | a stable URL for a case (`/support/tickets/T-AB12CD` works too), redirecting to its thread |

The screens inherit `config.parent_controller`, so your layout, your
authentication (`config.authenticate_method`) and your locale switching all
apply. `config.current_requester_method` names the person asking.

Doors go anywhere, including in partials shared with pages that have nothing
to do with support:

```erb
<%= link_to_support about: @order %>                                  <%# "Need help with Order SO1?" %>
<%= link_to_support about: @withdrawal, text: "Report a problem", class: "btn" %>
<%= link_to_support %>                                                <%# no subject: the wizard, step 1 %>
<%= support_unread_badge %>
```

`link_to_support` renders **nothing** when there is no requester, when the
record isn't `supportable`, or when it isn't theirs to ask about — and when
they already have a case open about it, it leads to that conversation instead
of opening a second one. Subjects travel as signed GlobalIDs (purpose
`:support_subject`, one hour) and are re-checked against `supportable_by?`
anyway; a token that is forged, expired or somebody else's is a 404, never a
403 with a hint.

In the chats inbox the desk appears **once**, as a grouped row. Before the
requester has ever written there is no row to group, so the engine puts a
door in its place (`config.inbox_entry = :always | :when_tickets | :never`) —
a support entry that only exists once you already have a ticket is
undiscoverable.

Hotwire Native hosts merge the engine's path rules into their own, AFTER any
rule that could swallow them:

```ruby
rules: [ *my_own_rules, *SupportDesk.native_path_rules ]
```

Order matters and the later rule wins: a host whose chats thread rule is
`^/messages/[^/]+$` already matches `/messages/support`, so rules placed
first would lose to it.

Both surfaces are pushed screens, never modals: every wizard step is a real
URL, so the back gesture and cold-boot deep links work.


### Every helper the requester views can use

| helper | what it renders |
|---|---|
| `link_to_support(about:, text:, **html)` | the door into the wizard (nothing when there is nobody to ask, or nothing they may ask about) |
| `support_unread_badge` | unread support messages, counted against the chats read horizon |
| `support_desk_styles` | the bundled stylesheet tag for your `<head>` |
| `support_reply_promise` | "We usually reply in under 24 hours", from `reply_within` |
| `support_ticket_state(ticket)` | "We're on it" · "We replied" · "We wrote to you" · "Closed" |
| `support_inbox_door?(viewer)` | whether the inbox should show the door instead of a row (`inbox_entry`) |
| `support_desk_record(key)`, `support_desk_avatar`, `support_desk_badge` | the desk as a counterpart: record, avatar (initials fallback), verified badge |
| `support_thread_path(ticket)` | where a case is read: its chats conversation |
| `open_support_ticket_about(record, requester)` | the open case about a record, or nil — what makes a door lead to the existing conversation |
| `support_human_door(ticket)` | the way to a person on a case an assistant is or was on, and the status line once one has been asked for (see [Assistants](#-assistants)) |

### Restyling

The views ship with a small bundled stylesheet and semantic classes (the list
reuses chats' own row classes, because a case *is* a conversation). The
stylesheet goes into your layout's `<head>`, so that layout needs a
`<%= yield :head %>` — every Rails app generated this decade has one. To make
the screens yours:

```bash
rails generate support_desk:views
```

That copies `app/views/support_desk/tickets/**` and the two rows this engine
contributes to chats' screens (`app/views/chats/slots/**`) into your app,
where they shadow the gem's copies — the Devise move. Delete your copy and
the default comes back; upgrade the gem and your copy is untouched. Every
view helper the templates use stays available afterwards, so an ejected copy
keeps working.
## The agent console

Three layers. Stop at whichever one you like — they are the same code, with
more of it written for you each time.

### Layer 1 — objects

The queue and presenters above. They have no view dependency at all, so a
console, a rake task, a Slack command and a JSON API all render from them.

### Layer 2 — two concerns

One word in your routes file draws every verb an agent needs:

```ruby
# config/routes.rb
namespace :madmin do
  resources :support_tickets, only: %i[index show new], concerns: :support_console
end
```

That adds member `reply take assign hand_off release close reopen note
change_topic send_draft reject_draft pause_assistant resume_assistant` and
collection `next` and `open_conversation`. The last four do nothing until an
assistant is configured, and the console never offers them before that. It
has to sit inside a `resources` block, since that is what those routes hang
off.
`new` stays yours: add it to `only:` when you render the form behind
`open_conversation` ("Write to someone").

The concern is seeded into every route set by a small prepend on Rails'
routing mapper, because routing concerns live in a Hash built per `draw`
and there is no registry a gem can add to. If you would rather not have
that, register it yourself and the patch stays out of your way:

```ruby
Rails.application.routes.draw do
  SupportDesk::ConsoleRoutes.register(self)

  namespace :madmin do
    resources :support_tickets, only: %i[index show new], concerns: :support_console
  end
end
```

Either way, a concern you define yourself under the same name wins.

Then:

```ruby
class Madmin::SupportTicketsController < Madmin::ApplicationController
  include SupportDesk::Console          # the verbs
  include SupportDesk::Console::Index   # optional: @queue, @scope, @tickets from params

  def current_agent = current_user      # or rely on config.current_agent_method
end
```

`index` and `show` stay yours — those are the UI, and Layer 1 is everything
they need. What the concern owns is the half that is easy to get wrong:

- `current_agent` has to be an eligible agent, or it's a **403**.
- `config.visible_desks_for` scopes *everything*, not just the ticket: the
  queue, the tab counts, the badge and `next` all read the same list, and
  `?desk=` can only name a desk that is already on it. A case on a desk this
  agent may not work is a plain **404** — never a 403 that confirms it
  exists. An agent with no desks at all gets a **403**, because that is a
  different sentence: there is no case in the question yet.
- `config.authorize_console` is consulted before every action, `index`
  included, for hosts with Pundit or CanCan. A hook that raises **denies**;
  the exception goes to `Rails.error`, not to the screen it was guarding.
- The console never accepts what it wouldn't offer. Every verb checks
  `ticket.actions_for(agent)` first, so a POST from a stale tab — replying
  to a case somebody closed while you were reading it — is refused with a
  reason rather than half-applied.
- Every refusal the domain can raise — a drop-in under `:assignee_only`, a
  hand-off by somebody who doesn't hold the ticket, a reply into a locked
  case — becomes a translated `flash[:alert]`. A console that 500s on a
  policy is a console nobody trusts.
- Each verb answers an HTML redirect or a Turbo Stream page refresh.
  Override `after_transition_path(ticket)` to land somewhere else.

```ruby
SupportDesk.configure do |config|
  config.current_agent_method = :current_user
  config.visible_desks_for    = ->(agent) { agent.billing? ? [ :billing ] : SupportDesk::Desk.all }
  config.authorize_console    = ->(agent, ticket, action) { AdminPolicy.new(agent).support?(action) }
end
```

Realtime is two lines, and the gem broadcasts to both on every message and
every transition:

```erb
<%= turbo_stream_from @ticket, :console %>          <%# the case %>
<%= turbo_stream_from SupportDesk.desk, :queue %>   <%# the queue %>
```

### Layer 3 — a generated console

```bash
rails generate support_desk:console madmin
```

Writes a controller that includes both concerns, a madmin resource so the
nav and search know tickets exist, and the whole view set (Tailwind, all
copy from locales) into `app/views/madmin/support_tickets/`. Everything it
writes is yours to edit; re-running it leaves your edits alone unless you
pass `--force`.

The views are copied out of `SupportDesk::ConsoleEngine` — the same
templates the mounted console renders, so there is one source of truth
rather than two sets that drift. They reference nothing private: tabs come
from `queue.tabs`, buttons from `actions_for`, and paths from the concern's
`console_ticket_path`, which reads *your* controller's route. That is why
the same file renders under `/admin/support` and under `/madmin`.

Add the badge to your admin nav:

```erb
<%= render "madmin/support_tickets/nav_badge", agent: current_user %>
```

#### No admin framework at all? Mount it instead

```ruby
mount SupportDesk::ConsoleEngine => "/admin/support"
```

The same Layer 3 views, already wired — nothing to generate and nothing to
route. It takes its layout and authentication from
`config.console_parent_controller`, the way the requester engine takes
`config.parent_controller`. Mounting it grants nothing: the agent check and
`authorize_console` still run.

Generate when you have an admin to put this inside and want the files;
mount when you don't. They render the same templates either way.

## Writing first

Most cases start with somebody asking. Some start with you:

```ruby
lucia.open_support_conversation_with!(alice, "We saw your refund bounced", about: withdrawal)
```

That is not a personal message from Lucía. It speaks as the desk, signs the
message with her name, lands in Alice's inbox as "Support", and seats Lucía
on the case from its first committed state — silently, because "Lucía is
taking care of your request" in a thread Alice never opened answers a
question nobody asked. It is the same seam `ask_support!` uses, so there is
one algorithm for cardinality, topics, subjects, conversations, events and
clocks:

```ruby
SupportDesk::Ticket.open!(requester: alice, message: "…", by: lucia)   # what the sugar calls
```

If Alice already has this conversation open, the message joins it as an
ordinary **reply** — under your desk's reply policy, which may well leave
the case with whoever holds it. Nothing about that is guessed from a count:
the opener knows whether it inserted, and the console says one true thing
either way.

Every case now records who opened it:

```ruby
ticket.opened_by             # => alice · lucia — a record, like closed_by
ticket.opened_by_requester?  # she asked
ticket.opened_by_support?    # we wrote first

SupportDesk::Ticket.opened_by_support.awaiting_requester
```

Her abuse limits stay hers: `open_rate_limit` and `max_open_tickets` count
only the cases she opened, so five conversations you started can never stop
her asking her first question. And `time_to_first_reply` is nil for a case
you opened — nobody was waiting for it.

### The line a thread opens with

```ruby
config.opening_line              = "You opened a conversation about “%{label}”. We usually reply within %{reply_within}."
config.opening_line_from_support = "%{desk} started this conversation with you about “%{label}”."
```

Both are posted inside the opening transaction, one database tick above the
message they introduce — so the line can never arrive after it, or not at
all. A String (with `%{label}`, `%{desk}`, `%{reply_within}`), an I18n key,
a block given the ticket, or nil. `opening_line` defaults to nil, so
existing threads open exactly as they do today; `opening_line_from_support`
has the gem's own copy as its default, because a message from a desk
somebody never wrote to has to explain itself.

### From the console

Add `new` to your routes and the queue grows a "Write to someone" button:

```ruby
resources :support_tickets, only: %i[index show new], concerns: :support_console
```

Tell the console how to find people and it grows a search box too;
otherwise it takes a GlobalID from one of your own pages (a user's admin
screen, an order) and says so:

```ruby
config.find_requester { |query| User.find_by(email: query.to_s.strip.downcase) }
```

#### What the compose form posts, and what comes back

The form is yours (`new.html.erb` — the generated one is a fine start); the
concern owns the request. `new` fills the draft it renders, `open_conversation`
sends it. Every field is read by name:

| param | what it is |
|---|---|
| `requester` | a GlobalID from one of your own pages — **authoritative**: a bad one is a refusal, never a fallback to the typed query |
| `requester_query` | what an agent typed, resolved by `config.find_requester` when no `requester` was supplied |
| `about` | a GlobalID of a `supportable` record; the topic comes with it |
| `topic` | a free-form topic path when there is no subject |
| `body`, `files[]` | the message: text, uploads, or Active Storage signed blob ids — text **or** an attachment is enough |
| `desk` | the desk key the agent is working; an explicit key that isn't a visible desk is refused, never silently swapped for the default |

GlobalIDs resolve only inside the classes that declared themselves
(`has_support_tickets`, `supportable`), so a token is an identifier and never
permission to call `find` on whatever it names. The concern sets `@requester`,
`@about`, `@topic`, `@body`, `@files` and `@requester_query` **before** it
looks anything up, so every refusal re-renders your `new` as a **422 with the
draft still in it** (for Turbo too — a stream refresh would throw it away);
success is a **303** to the case, with the flash `message_sent` whether the
case was opened or the message joined one the person already had open. The
refusals are distinct and each has its own copy under
`support_desk.console.errors`: `unknown_requester`, `not_a_requester` (a
closed account), `invalid_requester`, `invalid_subject`, `blank_message`,
`invalid_input`, `no_requester_lookup`, `writing_to_yourself`, `off_duty`.

Two named seams, for hosts that look people up their own way (a multi-tenant
host scopes **both**, since `find_requester` only guards the typed path):

```ruby
def support_conversation_requester   # the person, or nil; raise SupportDesk::Console::InvalidInput, :invalid_requester to refuse
def support_conversation_subject     # what it's about, or nil; the model re-checks supportable_by? at the write
```

Helpers your `new` template can read: `support_conversation_topics` (the
free-form leaves), `support_conversation_offered?` (show the door at all: on
duty, and `config.authorize_console` says yes for `:open_conversation` with a
nil ticket), `support_conversation_sendable?` (render the send button), and
`support_desk_record` (the desk being written as). When the message turns out
to be a reply into an open case, `config.authorize_console(agent, ticket,
:reply)` and `ticket.actions_for(agent)` are asked again, **under that case's
row lock**, before anything is written.

The verbs live in one table the router reads:
`SupportDesk::Console::MEMBER_VERBS` (reply take assign hand_off release close
reopen note change_topic) and `SupportDesk::Console::COLLECTION_VERBS`
(`next: :get, open_conversation: :post`).

### Who can be written to

`has_support_tickets if: :kept?` is the whole policy. When it turns false
the person can neither ask nor be written to, on every path — the console,
the model, a direct chats write — and nothing is hidden or deleted: the
transcript stays readable, the case stays in the queue, and agents can
still take notes and close it.

### Upgrading to 0.2

```bash
rails generate support_desk:upgrade   # copies the additive opened_by migration (the same file a fresh install runs)
rails db:migrate                      # backfills every existing case to its requester
rake support_desk:backfill_opened_by  # the idempotent catch-up, once the old processes are gone
```

**This is a drained cutover, not a rolling deploy.** 0.1 processes revalidate
`Assignment#reason` on `release!`/`close!`/`hand_off!` and reject the new
`opened` reason, so a case the desk opened must not exist while 0.1 code can
still touch it: migrate, pause support writes, stop and drain all old web
requests **and workers**, run the catch-up, verify
`SupportDesk::Ticket.where(opened_by_id: nil).count == 0` and
`SupportDesk.doctor` (its `provenance` check says exactly that), then start
only 0.2. A NULL `opened_by` is read as requester-opened in the meantime, so
quotas, labels and metrics stay right before the catch-up. Rolling back is a
code rollback, never a schema one; with staff-opened cases live, prefer
dropping `new`/`open_conversation` from your routes over downgrading. If you
would rather avoid the window, ship a `0.1.4` that only adds `opened` to
`Assignment::REASONS` first.

Requesters see one more state in their list — `support_desk.tickets.state
.opened_by_support` ("We wrote to you") — until they answer, and every error
the gem raises still inherits `SupportDesk::Error`; the new one is
`SupportDesk::NotARequester` (no `has_support_tickets`, or its `if:` said no).
`SupportDesk.humanize_duration` is where "1 day" / "4 horas" now comes from
(`Wizard.humanize_duration` still delegates to it).

## 🤖 Assistants

An assistant is an agent that happens to be a machine. She has a seat, a
name, a turn budget and a **level** that says what she may produce on this
case — and at the default level that is a proposal a person reads and sends,
signed by them.

The gem does not call a model. It emits one event and accepts a handful of
verbs; which provider you use, what you put in a prompt and what you spend
are yours. What lives here is the part nobody should write twice: who may
say what to whom, what happens when the customer writes again mid-answer,
and how a person takes over.

**Nothing in this section is on until you turn it on.** Without
`config.assistant`, `support_desk` behaves exactly as it did in 0.2.

### Two minutes

```bash
rails g support_desk:assistant Rose --disclosure signature
```

It writes `app/jobs/support/rose_turn_job.rb` and
`app/services/support/rose.rb`, and it **prints** the rest — it never edits
your initializer, because `config.assistant` is a policy decision and a
generator that wrote one would turn "let me look at this" into a live
assistant. Paste the stanza:

```ruby
# config/initializers/support_desk.rb
config.assistant :rose do |rose|
  rose.name            = "Rose"
  rose.autonomy        = :draft            # she proposes; a person sends
  rose.disclosure      = :signature        # REQUIRED — see below
  rose.max_turns       = 6
  rose.responds_within = 3.minutes
end
config.default_assistant = :rose
```

Wire the job to the one event the gem emits:

```ruby
SupportDesk.on(:assistant_turn, key: "support.rose.turn") do |ticket, assistant, _message, turn:|
  Support::RoseTurnJob.set(wait: 20.seconds).perform_later(ticket.id, assistant.key, turn)
end
```

And the job, which is the whole harness contract in nine lines:

```ruby
def perform(ticket_id, assistant_key, turn)
  ticket = SupportDesk::Ticket.find(ticket_id)
  return unless ticket.assistant_turn == turn       # the case moved on while we waited

  rose = SupportDesk.assistant(assistant_key)
  return unless ticket.assistant_policy(rose).may_observe?

  answer = Support::Rose.answer(ticket.brief, ticket.transcript)
  ticket.respond!(answer.text, by: rose, turn: turn, confidence: answer.confidence)
end
```

What a person sees next: a card at the top of the case that says "Propuesta
de Rose", the text, a confidence pill, the sources she cited, and three
buttons — **Enviar**, **Editar**, **Descartar**. The sent message is
*theirs*, signed with their name. The customer sees an answer from a human,
because it is one.

### Levels

`autonomy` is the ceiling she may ever work at. Every level is the one below
it plus its own verbs:

| level | she may | what it feels like |
|---|---|---|
| `:off` | nothing | configured, switched off |
| `:observe` | `note`, `escalate`, `release` | she reads and can leave a staff note or hand the case to a person; she never writes to the customer |
| `:draft` | the above + `draft` | **the default.** Every word goes through a person |
| `:reply` | the above + `reply`, `take` | she answers the customer and holds the case |
| `:resolve` | the above + `close` | she can close a case she holds once the customer has been answered |

```ruby
ticket.assistant_policy.level          # => :draft
ticket.assistant_policy.because        # => "topic payments caps rose at draft"
ticket.assistant_policy.may_reply?     # => false
ticket.assistant_policy.allowed_verbs  # => [:note, :escalate, :release, :draft]
```

### Ceilings and floors

A **ceiling** lowers what she may ever produce here. The lowest one wins,
and `because` names the single rule that decided it — so any refusal traces
back to one line of configuration:

| ceiling | set by |
|---|---|
| her autonomy | `rose.autonomy = :reply` |
| the topic | `topic :payments, assistant: :draft` — the minimum over the node and every ancestor, so a child can only tighten |
| your block | `rose.cap { |ticket| :draft if ticket.requester.try(:vip?) }` |
| the case | what a reopen writes (below) |
| a pause | a human switched her off on this case |

A **floor** lowers the level because of the case's state, after the ceilings:
she is deactivated, the case is closed, a person has been asked for, or a
human holds it.

```ruby
ticket.assistant_policy.ceilings   # => { assistant: :reply }   only the ones that apply
ticket.assistant_policy.floors     # => [:held_by_human]      Lucía took it: :reply becomes :draft
ticket.assistant_policy.to_h       # all five ceiling slots, spelled out, for a log line
```

Policy decides what she may **produce**. It never decides what a person can
see: the transcript, the case, the queue and the door to a human are the
same at every level, and a refusal is always a named reason on a record — an
`assistant_withheld` event, a policy stored in a proposal's metadata — never
silence.

### `respond!` and its three outcomes

`respond!` is the verb a harness should call. It hands over an answer and
lets policy decide what that answer becomes, so the harness never encodes
rules that change per case:

```ruby
outcome = ticket.respond!(text, by: rose, turn: turn, confidence: 0.82, sources: [{ title: "…", url: "https://…" }])

outcome.sent?        # it went to the requester (level :reply or above, and it was her turn)
outcome.drafted?     # a person will send it; outcome.draft is the row
outcome.withheld?    # nothing was written; outcome.reason is :policy or :not_your_turn
outcome.escalated?   # the budget ran out: the proposal is waiting AND so is a person
outcome.turn         # the successor turn, for a second action in the same run
```

`draft!` proposes regardless of level, for a host that has already decided it
wants a proposal. `reply!(by: rose, turn:)` and `note!(by: rose, turn:)` are
the ordinary verbs with a turn attached.

### The turn

`ticket.assistant_turn` is an opaque string (`"t7-r12"`) over an integer
bumped by **every** registered message and **every** transition. Every
assistant action requires it and consumes it:

```ruby
turn = ticket.assistant_turn      # read it before you call a model
ticket.respond!(answer, by: rose, turn: turn)
```

A model takes seconds and a customer can write again while it thinks. The
turn is what makes that safe: the action is compared against the case's
current revision **under its row lock**, and a late, retried or redelivered
one raises `SupportDesk::StaleTurn` and writes nothing. That one integer is
also why this gem has no idempotency keys, no claim rows and no leases —
"is this still the case you read?" is already answered.

Every verb of hers takes it, and that includes taking and giving back the
seat: `assign!(to: rose, by: rose, turn:)` and `release!(by: rose, turn:)`
require it when `by:` is an assistant (an omitted turn is an
`ArgumentError`, a stale one a `StaleTurn`), because a run that finished
after the case moved on must not release the seat a newer one took. A
**person's** calls are unchanged and take no turn.

Two consequences worth knowing:

- Check `ticket.assistant_turn == turn` in your job **before you spend
  money**. A mismatch means the newer turn's job already exists.
- A retry after a committed action is a `StaleTurn`, and that is correct:
  the work was done. Generated jobs `discard_on` it.

#### Ticket, then conversation

A turn is only as good as the reconciliation behind it, and reconciliation
is a `SELECT`: on its own it cannot exclude a message that commits a
millisecond later. Your customer never takes the case's row lock — they
press send, and chats writes a message.

What chats *does* take is the **conversation row**: every message insert
updates `chats_conversations` inside its own transaction. So every path
that speaks takes the ticket's row lock and then that row, before
reconciling. A question already in flight holds it, so we wait for it and
the turn goes stale; a question that starts after we hold it waits for us
and raises a turn of its own. **The order is always ticket → conversation**,
in this gem and in anything you add to it.

What that does not cover: a message whose `INSERT` was already stamped when
we won the row is still stamped earlier than the answer, so a transcript can
show a question above an answer that did not address it. That is a
genuinely simultaneous send, and its own turn follows.

> [!IMPORTANT]
> **This is a row lock, so it is PostgreSQL and MySQL.** SQLite has none:
> it serializes writes, and in WAL mode a reconciliation `SELECT` reads the
> last committed snapshot straight through a requester's open write
> transaction, so a question committing behind an answer is still missed
> there. Run PostgreSQL or MySQL for a production desk with an assistant —
> `SupportDesk.doctor` warns when you haven't.

### Proposals in the console

A pending proposal renders above the composer with its confidence, its
sources and its attachments, and goes stale visibly the moment anything on
the case moves.

```ruby
draft = ticket.pending_draft
draft.send!(by: lucia, seen_turn: ticket.assistant_turn)                  # verbatim
draft.send!(by: lucia, seen_turn: ticket.assistant_turn, body: "Casi: …") # edited
draft.reject!(by: lucia, reason: "no es eso")
```

`seen_turn` is the turn the reviewer's **page** was rendered with, and a
mismatch is a refusal, not a warning: approving a proposal from a page that
predates the customer's next message would send an answer into a
conversation that has moved on. There is no "send anyway" flag — the console
re-renders the case with the current turn and the reviewer's text still in
the box, and they submit again. One pending proposal per case, always: a
newer one, a takeover, a human reply or a pause supersedes the last.

A sent proposal is the **human's** message. `sent_body` keeps the edit, the
original body stays on the row, and `draft.edited?` / the `verbatim` and
`edited` scopes are the acceptance numbers you raise her level on.

### The two exits

Either side can ask for a person, and both do the same write: her seat is
released, the reason is recorded, the priority goes up, and a line lands in
the thread.

```ruby
ticket.escalate!(by: rose, turn: turn, reason: "refund_over_limit", summary: "Pidió el reembolso de …")
ticket.request_human!(by: alice)     # the requester's own door
```

Render the door in your thread — it is a partial in the requester engine,
and a helper:

```erb
<%= render "support_desk/tickets/human_door", ticket: ticket %>
<%= support_human_door(ticket) %>
```

It shows the button while an assistant is or has been in play on the case,
and the status line once a person has been asked for. **History counts**:
the door does not vanish because somebody edited an initializer after she
answered. Both exits reach the queue's `needs_human` tab, which appears only
on desks that have an assistant or a non-zero count.

### Disclosure

Required, with no default. Boot fails until you choose:

| mode | what the requester gets |
|---|---|
| `:signature_and_notice` | her messages are signed "Rose · asistente virtual" **and** the thread opens with a notice |
| `:signature` | signed; no notice |
| `:notice` | a notice; her messages are unsigned, from the desk |
| `:none` | nothing is said and nothing is signed |

**Your legal process decides this, not us.** The gem refuses to pick a
default because the right answer depends on a jurisdiction, a sector and a
risk appetite it knows nothing about. What it does guarantee is that the
choice is never invisible to *you*: whatever the mode, every machine-written
message carries `metadata["support_desk"]` naming the assistant, the mode,
the turn and the whole policy that allowed it, `ticket.export` labels it
`from: "assistant"` in **every** mode including `:none`, and the console
marks it for staff. What a customer is told is a product decision; what your
records say a machine wrote is not.

**Historical disclosure is captured per message.** The default Chats signature
renderer uses the assistant name and disclosure stored when the message was
sent. Renaming, changing mode or removing configuration does not rewrite old
signed bubbles. Human replies and human-approved drafts retain their normal
human signatures. The assistant row snapshot is a fallback for legacy messages
without provenance; their original disclosure cannot be reconstructed if it
was never stored.

A host's `Chats.config.message_signature` override remains authoritative. If
you customize it, preserve the human fallback as well as the assistant snapshot:

```ruby
Chats.configure do |config|
  config.message_signature = lambda do |message|
    stamp = message.metadata["support_desk"]
    name = if stamp.is_a?(Hash) && stamp["kind"] == "ai" && stamp["signed"] == true &&
              stamp["display_name"].is_a?(String) && stamp["display_name"].present?
      stamp["display_name"]
    else
      Chats.display_name_for(message.author)
    end
    I18n.t("chats.message.signature", name: name)
  end
end
```

### Humans outrank

- A person may answer a case she holds under **every** `reply_policy`.
  `:assignee_only` exists so two people don't answer at once, and she is not
  one.
- A human reply on her case takes it over and supersedes the pending
  proposal.
- `ticket.agents_to_notify` and `desk.humans` return people only. Notifying a
  machine is notifying nobody. (`desk.agents` includes her, and is an Array.)
- She can never send her own proposal, hand a case off, change a topic or
  attach a subject. She escalates instead.

### Pause, resume, and what a reopen remembers

```ruby
ticket.pause_assistant!(by: lucia, reason: "cliente enfadado")   # floors her at :off on THIS case
ticket.resume_assistant!(by: lucia)
```

Pausing releases her seat and throws away her pending proposal. Resuming
clears the pause and **nothing else** — a case cap and a request for a
person are different decisions made by different people, and only an
explicit hand-back (`assign!(to: rose, by: lucia)`) lifts those.

Reopening a case she closed leaves it unassigned and writes
`assistant_cap = "draft"` for the rest of its life. A case that came back is
a case where her answer was not the end of it.

### When the harness is down

Two scheduled tasks, and they are the difference between a delay and a
customer nobody answers:

```yaml
# config/recurring.yml
support_desk_release_silent_assistants:
  command: "SupportDesk.release_silent_assistants!"
  schedule: every minute
support_desk_redispatch_assistant_turns:
  command: "SupportDesk.redispatch_assistant_turns!"
  schedule: every 5 minutes
```

`release_silent_assistants` hands over every case she has sat on longer than
her `responds_within` without answering — a worker that stopped, a provider
that is down, a job that spent its last retry. It asks for a **person** on
each one, not just her seat back: a case that waited that long deserves one
whatever she would have said. `redispatch_assistant_turns` re-emits the turn
for cases nobody acted on, which is safe precisely because the turn is
consumed by the first action and every later one is a `StaleTurn`.

`release_silent_assistants` runs `SupportDesk.reclaim_assistant_seats!`
first, and you can run that on its own
(`rake support_desk:reclaim_assistant_seats`). It is a different question
from silence: it reads the **seats that exist** rather than the assistants
this process happens to have configured, and gives back every one whose
holder is switched off, no longer declared, or no longer allowed to hold a
case — with no `responds_within` and no overdue clock anywhere in it. That
is what makes `deactivate!` and a flag flipped off actually release her
cases, and it is why the doctor's seat checks keep running when the
configuration is gone.

`redispatch_assistant_turns` also repairs before it decides: a requester
message whose registration was lost after its commit leaves the clocks
describing a case that no longer exists, so the task looks for unregistered
**messages** and not only for idle clocks. The repair commits on its own,
which is what makes a dead process followed by nothing but this task end in
an actionable turn.

`rake support_desk:assistant_status` reports current counts without changing
tickets. Resolving configured assistants may create their identity rows or
refresh their name/disclosure snapshots. `SupportDesk.doctor` covers the same ground
with verdicts.

### What the model sees

> [!WARNING]
> **`ticket.brief` and `ticket.transcript` are what your harness sends to a
> third party.** Two fields in the brief are host data you chose:
> `Supportable#support_context` (about the thing the case is about) and
> `Requester#support_context` (about the person). `include_internal: true`
> adds the desk's private reasoning — notes agents left each other, and
> proposals a human rejected with the reason. Decide what belongs in a
> prompt before you fill those in, not after.

```ruby
brief = ticket.brief(include_internal: false, transcript_limit: 50)
brief.to_h        # versioned data — schema_version, desk, assistant, case, requester, transcript
brief.to_text     # the same facts as sectioned plain text
brief.policy      # what she may do here, and why

ticket.transcript.to_text
# [2026-09-18 10:02] Alice: No me han pagado
# [2026-09-18 10:03] Rose: Lo estoy mirando ahora mismo
# [2026-09-18 10:07] Lucía: Ya está resuelto [justificante.pdf]
```

A brief is **facts, never instructions**. There is not one imperative
sentence in it and there never will be: what the assistant should *do* with
a case is your prompt and your product. The one thing it states about
behaviour is `may` / `may_not`, and that is not advice either — it is the
authorization, straight off the policy, so a harness never has to re-derive
the rules it is working under.

The transcript speaks four roles (`:requester`, `:human`, `:assistant`,
`:system`) where `Ticket#role_of` speaks three: whose turn it is does not
change because a machine wrote the desk's last word, but a reader cares.
Deleted messages stay in it as tombstones, and an assistant's name follows
your configuration — rename her and the whole transcript renames, drop her
from the initializer and it keeps saying what the customer was actually
shown.

### Before you launch

- [ ] `SupportDesk.doctor.print` is green. It checks her bindings, that
      `Chats.display_name_for` answers for her, that no case she holds needs
      a person, that a turn subscriber exists, and that nothing has been
      idle longer than three times her `responds_within`.
- [ ] **Moderation covers both shapes.** A signed message has her as its
      author; a `:notice` or `:none` message has no author at all and is the
      desk's. Whatever owns your moderation has to catch the nameless one
      too.
- [ ] Notifiers subscribe to `draft_proposed` (a proposal is waiting),
      `ticket_escalated` and `human_requested` (somebody needs a person).
- [ ] The `_human_door` partial renders in your thread.
- [ ] Both rake tasks are scheduled, and you have watched them run once.
- [ ] `autonomy` is `:draft`, and topic caps are on money and identity.
      Raise her only when the acceptance rate on reviewed proposals says so.

### Reference

**Configuration**

| setting | type | default |
|---|---|---|
| `name` | String | the key, humanized |
| `avatar` | String, or a callable given the assistant | nil |
| `autonomy` | one of `AssistantPolicy::LEVELS` | `:draft` |
| `disclosure` | **required**: `:signature_and_notice` · `:signature` · `:notice` · `:none` | — |
| `max_turns` | positive Integer, or nil for unlimited (doctor warns) | 6 |
| `responds_within` | a Duration, or nil to disable the silent sweep (doctor warns) | 3 minutes |
| `may_open_conversations` | true / false | false |
| `hand_off_line` · `human_requested_line` · `disclosure_line` | String (`%{name} %{desk} %{reply_within}`), I18n key, block, or nil | the gem's copy |
| `hand_off_when` | block `(ticket, message)` → true / false / nil; anything else, or a raise, hands the case over | nil |
| `cap` | block `(ticket)` → a level or nil | nil |

Predicates: `signs?`, `notice?`, `disclosed?`, `may_open_conversations?`,
`line_for(setting, ticket)`. The four modes are
`AssistantConfiguration::DISCLOSURE_MODES`.

```ruby
config.assistant :rose { |rose| … }   config.assistant(:rose)   config.assistants   config.assistant?(:rose)
config.default_assistant = :rose
config.desk(:billing) { |desk| desk.assistant = :rose }        # an explicit nil DISABLES that desk
config.desk(:billing).assistant_key
topic :payments, assistant: :draft                              # Topic#assistant_cap — tightens only
acts_as_support_agent kind: :ai                                 # validated; see the upgrade note
```

**Module**

```ruby
SupportDesk.assistant(key = nil)        # the Assistant record, memoised; nil when none is configured
SupportDesk.reset_assistants!
SupportDesk.ai_actor?(record)
SupportDesk.release_silent_assistants!            # → Integer (runs reclaim_assistant_seats! first)
SupportDesk.reclaim_assistant_seats!              # → Integer; seats she may no longer sit in
SupportDesk.redispatch_assistant_turns!(older_than: 1.minute)   # → Integer
```

**`SupportDesk::Assistant`**

| | |
|---|---|
| `SupportDesk::Assistant.for(key)` / `.active` | found or created; the on-duty scope |
| `config` / `configured?` | her slice of the configuration; whether anything still declares her |
| `name` `avatar` `autonomy` `disclosure` `max_turns` `responds_within` `may_open_conversations?` | read through the configuration; `name` and `disclosure` fall back to the snapshot on her row, the rest to the safe answer |
| `disclosed?` `signs?` `notice?` | the mode, as predicates |
| `disclosed_name` `display_name` `to_s` `support_agent_name` `support_agent_avatar` | what a requester sees |
| `on_duty?` `support_capacity` | the agent contract |
| `deactivate!(by:, reason:)` / `activate!(by:)` | the cross-process kill switch; rows are never destroyed |
| `desks` / `held_tickets` | where she works, and what she is sitting on |

**`SupportDesk::AssistantPolicy`**

`LEVELS` · `RANK` · `VERBS_BY_LEVEL` · `ALL_VERBS` ·
`AssistantPolicy.for(ticket, assistant, hand_back: false)` · `level` ·
`because` · `ceilings` · `floors` · `assistant` · `ticket` ·
`at_least?(level)` · `may?(verb)` · `may_observe?` · `may_draft?` ·
`may_reply?` · `may_hold?` · `may_close?` · `allowed_verbs` ·
`forbidden_verbs` · `to_h` · `to_s` · `null?` (and `AssistantPolicy::Null`,
whose `because` says which of "no assistant here" and "not this desk's
assistant" it was).

**`SupportDesk::Ticket`**

```ruby
# verbs
respond!(body, by:, turn:, files:, confidence:, sources:, metadata:, request:)   # → Outcome
draft!(body, by:, turn:, …)                                                       # → Draft
escalate!(by:, reason:, summary:, turn:, request:)
assign!(to:, by:, reason:, note:, request:, turn:)   # turn: required when by: is an assistant
release!(by:, reason: :released, request:, turn:)    # idem
request_human!(by:, request:)          # by: must be the requester
pause_assistant!(by:, reason:) / resume_assistant!(by:)

# readers
assistant   assistant_policy(assistant = self.assistant, hand_back: false)   assistant_turn
assistant_in_play?   held_by_assistant?   human_required?   assistant_paused?   assistant_turns_left
assistant_message?(message)   transcript(limit: nil)   brief(include_internal:, transcript_limit:)
drafts   pending_draft   notes

# scopes
held_by_assistants   held_by_humans   needs_human   assistant_paused   assistant_capped
resolved_by_assistant   with_pending_draft   assistant_idle_since(time)
with_unregistered_requester_messages
```

Columns: `assistant_revision`, `last_requester_message_id`,
`assistant_turns_count`, `assistant_acted_at`, `assistant_paused_at`,
`assistant_paused_reason`, `assistant_cap`, `human_required_at`,
`human_required_reason`.

**`SupportDesk::Draft`**

`STATUSES` · `MAX_SOURCES` (20) · `MAX_SOURCE_TITLE` (500) ·
`MAX_SOURCE_URL` (2048) · `send!(by:, seen_turn:, body:, request:)` ·
`reject!(by:, reason:, request:)` · `pending?` `sent?` `rejected?`
`superseded?` `expired?` · `stale?` · `edited?` · `final_body` ·
`confidence_percent` · `author_key` · scopes `pending` `sent` `rejected`
`superseded` `expired` `reviewed` `verbatim` `edited` `by(author)`
`chronological` `newest_first`.

**`SupportDesk::Outcome`** — `action` `message` `draft` `policy` `reason`
`turn` · `sent?` `drafted?` `withheld?` `escalated?` · `to_h`.

**`SupportDesk::Transcript`** — `Turn(role:, name:, body:, at:,
attachments:, assisted:, message:)` with `requester?` `human?` `assistant?`
`system?` `assisted?` and `to_line`; `to_a` `to_h` `to_text` `last(n)`
`since(message)` `size`, Enumerable, and `limit:`. `to_h` carries
`truncated`, because a reader seeing the last 50 of 300 turns has to know.

**`SupportDesk::Brief`** — `SCHEMA_VERSION` · `to_h` · `to_text` · `policy`
· `include_internal?` · `transcript`.

**`Requester#support_context`** — overridable, `{}` by default, the same
meaning as `Supportable#support_context`. `ContextCard#requester_pairs`
renders it next to the subject's own `pairs`, and `to_h` carries it under
`requester.context`.

**`SupportDesk::Desk`** — `assistant` · `assistant?` · `humans` (people
only) · `agents` (people plus her, an Array).

**Events**

| event | arguments |
|---|---|
| `assistant_turn` | `ticket, assistant, message, turn:` — the only one a harness subscribes to |
| `draft_proposed` | `ticket, draft` |
| `draft_sent` | `ticket, draft, message, by:` |
| `draft_rejected` | `ticket, draft, by:, reason:` |
| `assistant_withheld` | `ticket, assistant, reason:, policy:` |
| `ticket_escalated` | `ticket, from:, reason:, by:` |
| `human_requested` | `ticket, by:, reason:` |
| `assistant_paused` / `assistant_resumed` | `ticket, by:` |

New `Event::KINDS`: `human_requested` `assistant_paused` `assistant_resumed`
`draft_sent` `draft_rejected` `assistant_withheld` — the last five join
`note` and `drop_in` in `Event::INTERNAL_KINDS`, which is what
`Event.requester_visible` excludes. An export says a person was asked for;
it never says a machine's proposal was discarded. `Event#summary` reads the
paragraph an escalation left.

**Errors** — `SupportDesk::NotAnAssistant` (an AI-kind actor that is not
this desk's assistant; a subclass of `NotAnAgent`),
`SupportDesk::AssistantNotAllowed` (carries `policy` and `verb`; a subclass
of `NotAllowed`), `SupportDesk::StaleTurn` (a subclass of
`InvalidTransition`, so `rescue InvalidTransition` still catches it).

**Console** — `MEMBER_VERBS` gains `send_draft` `reject_draft`
`pause_assistant` `resume_assistant`; helpers `support_pending_draft` and
`support_assistant`; `unavailable_reason` gains `"no_pending_draft"`. Picker
values are `SupportDesk.actor_key(agent)`. `Queue::TABS` gains
`:needs_human`, hidden by `visible_tabs` unless the desk has an assistant or
the count is non-zero.

**Requester engine** — `POST /tickets/:id/request_human`, and
`support_desk/tickets/_human_door` (local: `ticket`) behind the
`support_human_door(ticket)` helper.

**Rake** — `support_desk:release_silent_assistants` ·
`support_desk:reclaim_assistant_seats` ·
`support_desk:redispatch_assistant_turns` (`OLDER_THAN=60`) ·
`support_desk:assistant_status`.

**Doctor** — `assistants (config)` · `assistant turn subscriber` ·
`assistant authorship` · `assistant silence` · `assistant seats` ·
`assistant idle turns` · `drafts` · `ai agents without policy` · `message registrations`.

**Test helpers**

| helper | |
|---|---|
| `support_assistant(key = nil)` | the record |
| `respond_as(assistant, ticket, body, turn:, **options)` | → `Outcome` |
| `draft_as(assistant, ticket, body, turn:, **options)` | → `Draft` |
| `assert_pending_draft(ticket, body:)` / `refute_pending_draft` | `body:` takes a String (substring) or a Regexp |
| `assert_needs_human(ticket, reason:)` / `refute_needs_human` | |
| `assert_held_by_assistant(ticket, assistant = nil)` | |
| `refute_assistant_spoke(ticket)` | no machine has said anything to the requester |
| `assert_assistant_policy(ticket, level, because:)` | the level **and** the sentence |
| `with_assistant_config(key = nil, **overrides) { … }` | |
| `with_topic_assistant_cap(path, level) { … }` | rebuilds the frozen tree with one cap |

### Upgrading to 0.3.2 (including hosts without assistants)

0.3.2 adds `support_desk_message_registrations`, an internal receipt per text
message. A receipt, written with the ticket clocks and revision in one
transaction, distinguishes a replay from an unseen message. Timestamp and UUID
order are not evidence of delivery. Every unseen requester message invalidates
the turn, notifies the host and runs handoff detection once, even if its timestamp
is older; the SLA timestamps themselves never move backwards.

**This upgrade requires a drained cutover; it is not rolling-safe.** The table
is additive, but old processes cannot write receipts.

1. Pause support writes and drain old web requests and jobs. Keep the assistant
   disabled throughout the cutover.
2. Run `rails generate support_desk:upgrade`, inspect the new migration, then
   `rails db:migrate` while writes remain paused. Fresh installs get the same
   migration from `support_desk:install`.
3. The migration seeds existing text messages at or before each role's old
   clock as the historical baseline. Messages beyond those clocks remain
   discoverable by recovery. **Old data cannot prove whether a message behind
   the clock lost its callback.** Review suspect historical cases explicitly;
   the migration does not replay old notifications or reopen history en masse.
4. Start only 0.3.2 processes. Run `SupportDesk.doctor` and
   `SupportDesk.redispatch_assistant_turns!` before resuming support traffic.
   Recovery checks closed cases as well: `:reopen_on_reply` reopens them, while
   `:locked` preserves closure and dispatches no model work. Registration repair
   also runs on desks with no assistant configured.
5. Resume writes. An assistant rollout still requires its own staging checks
   and disclosure decision. The serialization guarantee still requires
   PostgreSQL/MySQL; SQLite does not acquire row locks.

Do not roll back to an old writer while serving traffic: it would leave missing
receipts. If a rollback is necessary, pause and drain first, keep the receipt
table, and re-establish the historical baseline before a later upgrade. Removing
a receipt deliberately permits processing that message again; it is an internal
recovery action, not a normal host API.

Public assistant `turn:` arguments must be the observed opaque token. Symbols
such as `:current` are refused; private outreach and automatic seat-taking do
not expose a public bypass. No new host-facing registration API is required.

### Historical upgrade from 0.2 to 0.3.0

The following describes the original assistants migration. When installing the
current release, also follow the 0.3.2 cutover above.

```bash
rails generate support_desk:upgrade   # current releases also copy the receipt migration
rails db:migrate
```

Additive and rolling-safe — unlike 0.2, no drain. Deploy **every** process to
0.3 before you add `config.assistant`: a 0.2 worker cannot honour a turn it
does not know about.

Four things change whether or not you configure an assistant:

- **A host model declared `acts_as_support_agent kind: :ai` is now refused
  for every support write, by it or to it** (`NotAnAssistant`). It used to
  be treated as a human. `kind:` is validated at declaration, and `doctor`
  warns about such classes. Only the desk's own `SupportDesk::Assistant` has
  machine authority.
- **Console picker values are actor keys**, not bare ids — an assistant and
  a user can share an integer id. A bare id is still accepted for one
  release, and only when exactly one pool member matches it.
- `Queue::TABS` gains `:needs_human`, hidden unless it is relevant.
- **Every registered message and every transition writes
  `assistant_revision`**, on every case, with or without an assistant. It is
  one nullable integer, it is what the turn is made of, and a 0.2 process
  reading those rows is unaffected — which is why step 3 matters in the
  other direction: a 0.2 *writer* leaves the counter behind.

And when you do configure one: `desk.agents` becomes an Array of humans plus
her and `desk.humans` is the human-only pool, `announce_assignments` never
announces her, a human reply takes her case over under every `reply_policy`
and supersedes the pending proposal, `close!` expires proposals, a reopen
after her close caps her at `:draft`, and `reply!` / `post_agent_message!`
accept `metadata:` and `turn:`.

`rose.deactivate!(by: owner)` is the kill switch: cross-process, within one
transition, no deploy.

## The wizard

"What do you need help with?" is a plain object, not a controller, so a host
that ejects the views, a native app or a JSON API can all drive the same
three steps: pick a topic, pick the thing it's about, write.

```ruby
wizard = SupportDesk::Wizard.new(current_user, params)
wizard.step        # :topic | :subject | :compose
wizard.choices     # the topics to offer, or the records to pick from
wizard.ask         # the prompt above them
wizard.existing_ticket   # "you already have a conversation open about this"
wizard.open!(params[:message])
```

Subjects travel as **signed GlobalIDs** and are re-checked against
`supportable_by?` anyway — a wizard that trusted a raw id would let anybody
open a ticket about anybody's order.

## Events

The gem emits; your app delivers. Multi-subscriber, error-isolated, after commit, and mirrored on `ActiveSupport::Notifications` as `"<event>.support_desk"`:

```ruby
SupportDesk.on(:ticket_opened)     { |ticket|      TicketNotifier.deliver(ticket.agents_to_notify) }
SupportDesk.on(:requester_replied) { |ticket, msg| TicketNotifier.deliver(ticket.agents_to_notify) }
SupportDesk.on(:ticket_transitioned) do |ticket, kind, by:, request:, payload:|
  AuditLog.log("support_ticket_#{kind}", actor: by, request: request, subject: ticket, **payload)
end
```

Pass `key:` from anywhere that runs more than once (a `to_prepare` block, an engine initializer) and re-registering replaces that subscriber instead of stacking a copy on every reload.

Keep push titles and bodies generic — `ticket.notification_title` is safe for previews.
`ticket.notification_body` contains case details for an authenticated feed, not a lock screen.



The whole catalogue, with the arguments each subscriber receives:

| event | arguments | when |
|---|---|---|
| `ticket_opened` | `ticket` | a case was **inserted** — by a requester or by the desk; check `ticket.opened_by_support?` before paging your team about their own message |
| `requester_replied` | `ticket, message` | a requester message registered, other than the one that opened the case |
| `agent_replied` | `ticket, message` | a desk message registered, other than the desk's own opening message |
| `ticket_assigned` | `ticket, assignment` | take, assign, or (later) routing — not the silent seat a desk-opened case starts with |
| `ticket_handed_off` | `ticket, assignment, from:, note:` | |
| `ticket_released` | `ticket, from:, reason:` | |
| `ticket_closed` / `ticket_reopened` | `ticket, by:` | `by:` is the requester when their own reply reopened it |
| `ticket_topic_changed` | `ticket, from:, to:, by:` | |
| `subject_attached` | `ticket, subject, by:` | |
| `note_added` | `ticket, event` | internal notes never reach the conversation |
| `assistant_turn` | `ticket, assistant, message, turn:` | there is something for an assistant to answer — the only event a harness subscribes to (see [Assistants](#-assistants)) |
| `draft_proposed` | `ticket, draft` | a proposal is waiting for a person |
| `draft_sent` | `ticket, draft, message, by:` | |
| `draft_rejected` | `ticket, draft, by:, reason:` | |
| `assistant_withheld` | `ticket, assistant, reason:, policy:` | `respond!` wrote nothing, and the policy that refused is in the payload |
| `ticket_escalated` | `ticket, from:, reason:, by:` | a case was handed to a person |
| `human_requested` | `ticket, by:, reason:` | the requester pressed the door, or a `hand_off_when` phrase fired |
| `assistant_paused` / `assistant_resumed` | `ticket, by:` | |
| `ticket_transitioned` | `ticket, kind, by:, request:, payload:` | once per event row — the audit-log hook |

`ticket.agents_to_notify` is the assignee, or the whole on-duty pool while
nobody holds the case — the gem computes it so every host gets "assignee or
everyone" right. System messages (opening lines, closure notices) never emit
anything and never move the clocks.

## Errors

Every error inherits `SupportDesk::Error`, so `rescue SupportDesk::Error`
catches anything support-specific; the console turns each into a translated
flash. `ConfigurationError` (boot) · `ActorMissing` (a transition with no
`by:` and no `Current.actor`) · `NotAnAgent` · `NotARequester` (no
`has_support_tickets`, or its `if:` said no) · `NotTheAssignee` (a hand-off
by somebody who doesn't hold the case) · `NotAllowed` (policy: a drop-in
under `:assignee_only`, somebody else's record, a hidden topic, an agent
writing to themselves) · `InvalidTransition` and its subclass `Locked` (a
closed case on a desk that locks them, or a requester who can no longer be
written to) · `UnknownTopic` · `NotSupportable` · `RateLimited` ·
`TooManyOpenTickets`. With an assistant configured, three more:
`NotAnAssistant` (an AI-kind actor that isn't this desk's own assistant — a
subclass of `NotAnAgent`), `AssistantNotAllowed` (her policy forbids the
verb; it carries the `policy` and the `verb`, so you can log the rule
instead of parsing the sentence) and `StaleTurn` (the case changed since she
read it — a subclass of `InvalidTransition`, so anything rescuing that
still catches it).

## Locales

`es` and `en` ship with the gem, under `support_desk.*` (requester screens,
system lines, notifications, queue tabs, statuses, channels) and
`support_desk.console.*` (queue, case page, compose form, flashes, errors).
Your own locale files **outrank** the gem's — Rails loads every engine's
locales first and the app's last — so override any key in your `es.yml` and
the gem's copy loses. The ones hosts usually touch: `support_desk.topics.<path>.label`
(and `.ask`, `.hint`), `support_desk.queue.tabs.*`,
`support_desk.system.assigned`, `support_desk.thread.*`,
`support_desk.console.flashes.*` and `support_desk.console.errors.*`. The
suite asserts both languages carry exactly the same keys.

## Doctor

```ruby
SupportDesk.doctor.print   # or .ok? in CI
```

Configuration: `requester_class`, `agents` (the block resolves to records),
`topics` (a tree with a way out), `opening lines` (every static line
interpolates, every I18n key exists), `supportables` (every `about:` class is
supportable), `find_requester` (callable, one argument), `engine mount`,
`parent controllers`. Chats seams: `chats subscribers`, `chats authorship`,
`desk messager`. Data invariants: `conversations` (every ticket has one),
`assignments` (at most one open per case), `assignee pointers`, `provenance`
(no half-NULL `opened_by`; warns on legacy NULL rows and names the backfill
task), `awaiting` (agrees with the transcript), `references` (unique).
Assistants (only where one is configured): `assistants (config)`,
`assistant turn subscriber`, `assistant serialization` — which warns when
the adapter takes no row locks, because the turn rests on them —
`assistant authorship`, `assistant silence`, `assistant seats`, `assistant
idle turns`, `drafts`, and `ai agents without policy`, which warns about any
host class declared `kind: :ai`, since every support write by it is refused.
The seat and draft checks also run once she is no longer configured, since
that is exactly when a seat gets stranded.

## Compatibility

Rails 7.2, 8.0 and 8.1; Ruby >= 3.2; PostgreSQL, SQLite and MySQL; bigint or UUID primary keys (the migration follows your app's `primary_key_type`).

PostgreSQL and SQLite enforce unique new-case creation, one open assignment per ticket and
one pending proposal per ticket with **partial unique indexes**. New submissions reuse an existing open case. Reopening
historical cases is deliberately exempt from new-case deduplication: if a newer case
already exists, both histories remain open and support is notified of the reply. No
conversation is silently merged, closed or discarded. MySQL has no partial indexes,
so these guarantees are model-only there; the suite's matrix is SQLite and PostgreSQL.

## Testing

The gem is tested with Minitest against a real dummy host app: models and transitions, full request cycles through both the requester engine and the console, the generators, every authorization negative, and the wizard's three Turbo Frames driven in a real browser — a frame is only a frame in one.

```bash
bundle exec rake ci              # everything a pull request has to pass
bundle exec rake test            # just the suite
bundle exec appraisal install    # then test across Rails versions:
bundle exec appraisal rails-7.2 rake test
bundle exec appraisal rails-8.1 rake test
```

`rake ci` is `rake test`, `rake rubocop` and `rake brakeman`. The suite runs against SQLite by default, and against PostgreSQL with `DATABASE_URL` set.

**Testing your own app** — the gem ships the helpers its own suite uses, so your acceptance tests and ours describe the same behaviour:

```ruby
include SupportDesk::TestHelpers

ticket = open_support_ticket(for: users(:alice), about: orders(:one), message: "…")
written = open_support_ticket(for: users(:alice), by: users(:lucia), message: "…")   # the desk writes first
reply_as users(:lucia), ticket, "…"
assert_awaiting_requester ticket
assert_ticket_event ticket, :handed_off, from: users(:lucia), to: users(:pedro)

with_support_config(reply_policy: :assignee_only) { … }
```

Everything the module gives you:

| helper | |
|---|---|
| `open_support_ticket(for:, message:, about:, topic:, by:)` | a case, the way a requester opens one — or the desk, with `by:` |
| `reply_as(agent, ticket, body, files:)` | answer; returns the `Chats::Message` |
| `ask_again(ticket, body)` | the requester writes again |
| `assert_awaiting_reply` / `assert_awaiting_requester` | who owes the next word (these reload the ticket) |
| `assert_ticket_open` / `assert_ticket_closed` | status |
| `assert_assigned_to(ticket, agent)` / `assert_unassigned` | the seat |
| `assert_ticket_event(ticket, kind, from:, to:, by:)` / `refute_ticket_event` | the timeline |
| `with_support_config(desk = :default, **overrides) { … }` | different desk settings for one block, put back afterwards |
| `capture_support_events(*names) { … }` | `[[name, args, kwargs], …]` of what the block emitted; unsubscribes on the way out |

And, with an assistant configured, the ones its own suite uses — `support_assistant`, `respond_as`, `draft_as`, `assert_pending_draft` / `refute_pending_draft`, `assert_needs_human` / `refute_needs_human`, `assert_held_by_assistant`, `refute_assistant_spoke`, `assert_assistant_policy`, `with_assistant_config` and `with_topic_assistant_cap`. They are documented in [Assistants](#-assistants).

Between examples, `SupportDesk.reset!` clears configuration, subscribers,
desks and registries; `SupportDesk.reset_desks!` only forgets the memoised
desk records.

## Module-level API

```ruby
SupportDesk.configure { |config| … }   SupportDesk.config   SupportDesk.configured?
SupportDesk.desk(key = :default)       # the Desk record, found or created, memoised
SupportDesk.assistant(key = nil)       # the Assistant record, memoised; nil when none is configured
SupportDesk.reset_assistants!          SupportDesk.ai_actor?(record)
SupportDesk.release_silent_assistants!            # the net under a dead harness (schedule it)
SupportDesk.reclaim_assistant_seats!              # seats an assistant may no longer sit in
SupportDesk.redispatch_assistant_turns!(older_than: 1.minute)
SupportDesk.find_topic("billing/invoice")
SupportDesk.on(event, key: nil) { … }  SupportDesk.off(event, key)
SupportDesk.doctor
SupportDesk.native_path_rules(mount:, title:)   # Hotwire Native path rules for the requester screens
SupportDesk.humanize_duration(24.hours)          # "1 day", in the reader's language
SupportDesk.actor_key(record)                    # a stable key for an actor (GlobalID param); what event payloads store
SupportDesk.requester_class?(klass)  .supportable_class?(klass)  .agent_class?(klass)
SupportDesk.eligible?(record, condition)         # how both macros read their `if:`
SupportDesk.subscribe_to_chats!                  # the `:message_created` listener; idempotent
SupportDesk::VERSION
```

## Development

After checking out the repo, run `bundle install`, then `bundle exec rake ci`. The dummy app lives in `test/dummy` and mounts all three surfaces the way a real host does: the requester engine at `/messages/support`, `chats` at `/messages`, and the turnkey console at `/admin/support` — plus the same console again inside a host-owned `madmin` namespace, because "the console uses only the public API" is a claim that needs a second implementation to be worth anything.

`chats` is the kernel this gem is a product on and the two are developed in lockstep, so the Gemfile points at a sibling checkout (`../chats`) whenever this gem needs a `chats` that is not on rubygems yet. It currently requires `chats` ~> 0.3 (the `verified:` messager option).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/support_desk. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
