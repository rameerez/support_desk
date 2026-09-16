# 🎫 `support_desk` - Customer support for your Rails app, as conversations

[![Gem Version](https://badge.fury.io/rb/support_desk.svg)](https://badge.fury.io/rb/support_desk)

`support_desk` gives your Rails app a **support desk**: tickets that are real conversations. Somebody asks for help about something in your app (a ride, an order, a withdrawal) or about nothing in particular, your desk answers, humans sign the answers, and your team works a queue.

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

## Testing

```ruby
include SupportDesk::TestHelper

ticket = open_support_ticket(for: users(:alice), about: orders(:one), message: "…")
reply_as users(:lucia), ticket, "…"
assert_awaiting_requester ticket
assert_ticket_event ticket, :handed_off, from: users(:lucia), to: users(:pedro)

with_support_config(reply_policy: :assignee_only) { … }
```

## Compatibility

Rails 7.2, 8.0 and 8.1; Ruby >= 3.2; PostgreSQL, SQLite and MySQL; bigint or UUID primary keys (the migration follows your app's `primary_key_type`). PostgreSQL additionally enforces "one open ticket about one thing" and "one open assignment per ticket" with partial unique indexes.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/support_desk.

`bundle exec rake ci` runs everything a pull request has to pass: the suite, the linter and the security scanner. Individually those are `rake test`, `rake rubocop` and `rake brakeman`. The suite runs against SQLite by default and against PostgreSQL or MySQL with `DATABASE_URL` set, and `bundle exec appraisal rake test` runs it across the supported Rails versions.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
