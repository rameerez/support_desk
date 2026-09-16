# 🎫 `support_desk` - Customer support for your Rails app, as conversations

[![Gem Version](https://badge.fury.io/rb/support_desk.svg)](https://badge.fury.io/rb/support_desk) [![Build Status](https://github.com/rameerez/support_desk/workflows/Tests/badge.svg)](https://github.com/rameerez/support_desk/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=support_desk)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=support_desk)!

`support_desk` gives your Rails app a **support desk**: tickets that are real conversations. Somebody asks for help about something in your app (a ride, an order, a withdrawal) or about nothing in particular, your desk answers, humans sign the answers, and your team works a queue.

Here is the whole thing — the kind of support desk a DoorDash, an Uber Eats or a Grab needs — running on a made-up delivery app called Pepperbox. These are the **bundled views**, unmodified, themed by the host with a handful of CSS variables:

| One row, every case | Pick a topic | Which order? |
|:---:|:---:|:---:|
| ![The chats inbox, with every support conversation folded into a single row](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/01-inbox.png) | ![The wizard's first step: a list of support topics](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/02-topics.png) | ![The wizard's second step: the requester's own orders](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/03-subject.png) |
| **Say what happened** | **Signed by a human** | **The agent queue** |
| ![The composer, with a card naming the order the case is about](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/04-compose.png) | ![The conversation, with an agent's answer signed by name](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/05-thread.png) | ![The agent queue, with tabs, counts and waiting chips](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/06-queue.png) |
| **The whole case** | **Notes stay inside** | **Hand it over** |
| ![One case: transcript on the left, context card on the right](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/07-case.png) | ![The internal note composer, which never reaches the customer](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/08-note.png) | ![The timeline: assigned, noted, answered, handed off](https://raw.githubusercontent.com/rameerez/support_desk/main/screenshots/09-handoff.png) |

It is a product gem on the [`chats`](https://github.com/rameerez/chats) kernel: chats owns the transcript, realtime, attachments, read state and moderation; `support_desk` owns the case — topics, assignment, SLA clocks, events and the console API.

Every app eventually needs a support inbox, and everyone rebuilds the same ticket table, the same "assigned to me" tab, the same "which order is this about?" picker and the same email bridge. `support_desk` is that whole rebuild, done once, done right, on top of the messaging you already have.

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

ticket = alice.ask_support!("My order never arrived", about: order)
ticket.assign!(to: lucia, by: lucia)
ticket.reply!("We're on it", by: lucia)
ticket.close!(by: lucia)
```

That's a ticket, a conversation, an assignment history, an append-only audit trail and four events your app can subscribe to.

## Quickstart

Add the gem:

```ruby
gem "support_desk"
```

Install it (creates the migration + an annotated initializer):

```bash
bundle install
rails generate support_desk:install
rails db:migrate
```

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

## The model macros

### `has_support_tickets(desk: :default, as: nil)`

Adds exactly four methods to whoever asks for help:

| method | what it does |
|---|---|
| `support_tickets` | `has_many`, newest first. Chain the scopes: `alice.support_tickets.open.about(order)` |
| `ask_support!(message, about:, topic:, files:, via:)` | opens the ticket, posts the first message, emits `ticket_opened`, and hands back the `Ticket` — or the open one they already have about the same thing |
| `awaiting_support_reply?` | is the desk holding any of their questions? |
| `unread_support_count` | for a nav badge, counted against the chats read horizon |

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

Makes someone able to answer. Agents are never chats participants — the desk sends, the agent *authors* — so this needs no messaging setup at all. It adds `support_agent?`, `support_agent_name`, `support_agent_avatar`, `on_duty?`, `support_capacity` and `support_queue`, and **no verbs**: the ticket is the subject of every sentence.

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

### Scopes

```ruby
SupportDesk::Ticket
  .open .closed .not_closed .assigned .unassigned .assigned_to(lucia)
  .awaiting_reply .awaiting_requester
  .waiting_over(4.hours) .at_risk .overdue
  .about(order) .about_any(Order) .on_topic(:billing)
  .for_desk(:billing) .opened_via(:email) .opened_between(range)
  .most_urgent_first .recent_activity_first .newest_first
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
  resources :support_tickets, only: %i[index show], concerns: :support_console
end
```

That adds member `reply take assign hand_off release close reopen note
change_topic` and collection `next`. It has to sit inside a `resources`
block, since that is what those routes hang off.

The concern is seeded into every route set by a small prepend on Rails'
routing mapper, because routing concerns live in a Hash built per `draw`
and there is no registry a gem can add to. If you would rather not have
that, register it yourself and the patch stays out of your way:

```ruby
Rails.application.routes.draw do
  SupportDesk::ConsoleRoutes.register(self)

  namespace :madmin do
    resources :support_tickets, only: %i[index show], concerns: :support_console
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

Keep notification titles generic — `ticket.notification_title` is — and put the detail in the body. A lock screen shouldn't spell out what somebody's support case is about.

## Compatibility

Rails 7.2, 8.0 and 8.1; Ruby >= 3.2; PostgreSQL, SQLite and MySQL; bigint or UUID primary keys (the migration follows your app's `primary_key_type`).

PostgreSQL and SQLite additionally hold the two cardinality rules — one open ticket about one thing, one open assignment per ticket — as **partial unique indexes**, so a race loses at the database and not merely at the model. MySQL has no partial indexes, so there those two rules are model-only; that is why the suite's own matrix is SQLite and PostgreSQL.

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
reply_as users(:lucia), ticket, "…"
assert_awaiting_requester ticket
assert_ticket_event ticket, :handed_off, from: users(:lucia), to: users(:pedro)

with_support_config(reply_policy: :assignee_only) { … }
```

## Development

After checking out the repo, run `bundle install`, then `bundle exec rake ci`. The dummy app lives in `test/dummy` and mounts all three surfaces the way a real host does: the requester engine at `/messages/support`, `chats` at `/messages`, and the turnkey console at `/admin/support` — plus the same console again inside a host-owned `madmin` namespace, because "the console uses only the public API" is a claim that needs a second implementation to be worth anything.

`chats` is the kernel this gem is a product on and the two are developed in lockstep, so the Gemfile points at a sibling checkout (`../chats`) whenever this gem needs a `chats` that is not on rubygems yet. It currently requires `chats` ~> 0.3 (the `verified:` messager option).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/support_desk. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
