# 🎫 `support_desk` - Customer support for your Rails app, as conversations

[![Gem Version](https://badge.fury.io/rb/support_desk.svg)](https://badge.fury.io/rb/support_desk) [![Build Status](https://github.com/rameerez/support_desk/workflows/Tests/badge.svg)](https://github.com/rameerez/support_desk/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=support_desk)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=support_desk)!

`support_desk` gives your Rails app a **support desk**: tickets that are real conversations. Somebody asks for help about something in your app (a ride, an order, a withdrawal) or about nothing in particular, your desk answers, humans sign the answers, and your team works a queue.

Here is the whole thing — the kind of support desk a DoorDash, an Uber Eats or a Grab needs — running on a made-up delivery app called Pepperbox. These are the **bundled views**, unmodified, themed by the host with a handful of CSS variables:

| One row, every case | Pick a topic | Which order? |
|:---:|:---:|:---:|
| ![The chats inbox: every support conversation folded into one official, verified row](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/01-inbox.png) | ![The wizard's first step: a list of support topics](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/02-topics.png) | ![The wizard's second step: the requester's own orders](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/03-subject.png) |
| **Say what happened** | **Signed by a human** | **The agent queue** |
| ![The composer, with a card naming the order the case is about](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/04-compose.png) | ![The conversation, with the desk's verified badge and an answer signed by the agent who wrote it](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/05-thread.png) | ![The agent queue, with tabs, counts and waiting chips](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/06-queue.png) |
| **The whole case** | **Notes stay inside** | **Hand it over** |
| ![One case: what it is about, and the transcript the requester sees](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/07-case.png) | ![The internal note composer, which never reaches the customer](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/08-note.png) | ![Handing a case to a colleague, above the history of every hand-off before it](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/09-handoff.png) |

It is a product gem on the [`chats`](https://github.com/rameerez/chats) kernel: chats owns the transcript, realtime, attachments, read state and moderation; `support_desk` owns the case — topics, assignment, SLA clocks, events and the console API.

Every app eventually needs a support inbox, and everyone rebuilds the same ticket table, the same "assigned to me" tab, the same "which order is this about?" picker and the same email bridge. `support_desk` is that whole rebuild, done once, done right, on top of the messaging you already have.

**Contents:** [Example](#-example) · [Quickstart](#quickstart) · [Configuration reference](#configuration-reference) · [Topics](#topics) · [Model macros](#the-model-macros) · [Tickets](#tickets) · [Queues and presenters](#queues-and-presenters) · [The requester experience](#the-requester-experience) · [The agent console](#the-agent-console) · [Writing first](#writing-first) · [The wizard](#the-wizard) · [Events](#events) · [Errors](#errors) · [Locales](#locales) · [Doctor](#doctor) · [Compatibility](#compatibility) · [Testing](#testing) · [Module-level API](#module-level-api)

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
```

That's a ticket, a conversation, an assignment history, an append-only audit trail and four events your app can subscribe to.

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

`about`, `candidates`, `desk`, `route_to`, `priority`, `only` and `retired`
are inherited down the branch; copy never is. Labels come from
`support_desk.topics.<path>.label` in your locale files (`ask` and `hint`
alongside).

```ruby
ticket.topic                    # a SupportDesk::Topic value object
ticket.topic.path               # "billing/invoice"
ticket.topic.label              # "Invoice"
ticket.topic.full_label         # "Billing › Invoice"
ticket.topic.under?(:billing)   # true
ticket.topic.free_form?  .subject_required?  .retired?  .priority  .about  .icon
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
`reopened` `topic_changed` `subject_attached` `note` — plus kinds reserved for
later releases), an `actor` and a `payload`, and is read-only once written.

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
q.mine  q.unassigned  q.awaiting  q.open  q.closed    # relations
q.counts     # { awaiting: 4, mine: 2, … } in ONE query
q.badge      # the nav number, cached 30s per agent
q.next       # the most urgent thing this agent could pick up
q.tabs       # [[:awaiting, "Needs a reply", 4], …]

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
change_topic` and collection `next` and `open_conversation`. It has to sit
inside a `resources` block, since that is what those routes hang off.
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
`TooManyOpenTickets`.

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

## Compatibility

Rails 7.2, 8.0 and 8.1; Ruby >= 3.2; PostgreSQL, SQLite and MySQL; bigint or UUID primary keys (the migration follows your app's `primary_key_type`).

PostgreSQL and SQLite enforce unique new-case creation and one open assignment per ticket
with **partial unique indexes**. New submissions reuse an existing open case. Reopening
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

Between examples, `SupportDesk.reset!` clears configuration, subscribers,
desks and registries; `SupportDesk.reset_desks!` only forgets the memoised
desk records.

## Module-level API

```ruby
SupportDesk.configure { |config| … }   SupportDesk.config   SupportDesk.configured?
SupportDesk.desk(key = :default)       # the Desk record, found or created, memoised
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
