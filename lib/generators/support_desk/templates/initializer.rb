# frozen_string_literal: true

SupportDesk.configure do |config|
  # ==========================================================================
  # WHO ASKS, WHO ANSWERS
  # ==========================================================================
  #
  # The model that asks for help — the one with `has_support_tickets`. It
  # must also be a chats messager (`acts_as_messager`): a requester holds a
  # seat in the conversation behind every one of their tickets.
  #
  # Default: "User"
  config.requester_class = "User"

  # The agent pool: who gets notified while a ticket is unassigned, who
  # appears in the "assign to" picker, and who routing may choose. A block
  # (or a lambda) returning a relation — it's called when it's needed, so it
  # always reflects today's staff.
  #
  # config.agents { User.where(admin: true) }

  # Who may ask, and who may answer, record by record — the macros' `if:`:
  #
  #   class User < ApplicationRecord
  #     has_support_tickets if: :kept?          # a closed account can neither
  #     acts_as_support_agent if: :admin?       # ask nor be written to
  #   end
  #
  # `has_support_tickets if:` is a WRITE rule, not a screen rule: the thread
  # and its history stay readable when it turns false.

  # How the console finds the person an agent types in "Write to someone":
  # email, phone, handle — your call. Given the typed string, return a
  # requester record or nil. Without it the console accepts only a GlobalID
  # from one of your own pages.
  #
  # config.find_requester { |query| User.find_by(email: query.to_s.strip.downcase) }

  # ==========================================================================
  # CONTROLLER INTEGRATION
  # ==========================================================================
  #
  # The requester-facing engine inherits from your controller, so your
  # layout, helpers, auth and locale apply to the support screens
  # automatically.
  #
  # config.parent_controller = "::ApplicationController"
  #
  # The console (the optional ConsoleEngine and the generated console)
  # inherits from your admin framework's base controller instead.
  #
  # config.console_parent_controller = "::Madmin::ApplicationController"
  #
  # How the engine finds the person asking, and the console the person
  # answering. The defaults work with Devise out of the box.
  #
  # config.current_requester_method = :current_user
  # config.current_agent_method = :current_user
  #
  # Your own authentication filter, run before every requester-facing
  # screen, so a logged-out visitor meets YOUR login flow.
  #
  # config.authenticate_method = :authenticate_user!

  # ==========================================================================
  # THE DESK
  # ==========================================================================
  #
  # What requesters see as the counterpart in their inbox.
  #
  # config.name = "Soporte"
  #
  # An asset path, a URL, or ->(desk) { … }. Anything image_tag accepts.
  #
  # config.avatar = "support-avatar.png"
  #
  # The address the email channel answers from (support_desk 0.2).
  #
  # config.email = "soporte@example.com"

  # ==========================================================================
  # TOPICS — what a ticket can be about
  # ==========================================================================
  #
  # A tree, defined here, stored on the ticket as a stable path
  # ("payments/withdrawal"). Topics carry behaviour — which records they
  # attach, which picker, which routing, which prefill — which is why they
  # live in code rather than in a database table somebody edits at 3am.
  #
  # Labels come from i18n (support_desk.topics.<path>.label) unless you pass
  # `label:`. `other` is the free-form leaf; a taxonomy without an exit is
  # how people pick the wrong topic, so the gem warns at boot when it's
  # missing.
  #
  # config.topics do
  #   topic :ride, about: Ride
  #   topic :payments do
  #     topic :withdrawal, about: Payouts::Withdrawal
  #     topic :invoice, desk: :billing
  #   end
  #   topic :account, only: ->(user) { user.onboarded? }
  #   topic :safety, priority: :urgent
  #   other
  # end

  # ==========================================================================
  # BEHAVIOUR
  # ==========================================================================
  #
  # Who may answer a ticket somebody else holds:
  #   :anyone         the reply posts, signed by the drop-in; an unheld
  #                   ticket is taken by whoever answers first (small teams)
  #   :take_over      replying reassigns the ticket to the replier (shifts)
  #   :assignee_only  raises; the console offers "Tomar" instead (regulated)
  #
  # config.reply_policy = :anyone
  #
  # Whether the requester is told who picked up their ticket:
  #   :first_only  the first human to take it ("Lucía se ocupa de tu consulta")
  #   :always      hand-offs too
  #   :never
  #
  # config.announce_assignments = :first_only
  #
  # The system line a thread opens with, posted inside the opening
  # transaction and before the first message. A String with %{label},
  # %{desk} and %{reply_within}, a Symbol naming an I18n key, a block given
  # the ticket, or nil for no line at all.
  #
  # The second one is for a case the DESK opened
  # (`lucia.open_support_conversation_with!(alice, "Vimos que…")`): it has a
  # default, because a message from a desk somebody never wrote to has to
  # explain itself.
  #
  # config.opening_line = "Has abierto una conversación sobre «%{label}». Te contestamos aquí."
  # config.opening_line_from_support = "%{desk} ha abierto esta conversación contigo sobre «%{label}»."
  #
  # What a requester writing into a closed ticket does:
  #   :reopen_on_reply  the case comes back (no wall, no dead end)
  #   :locked           the composer is replaced by a notice
  #
  # config.closed_tickets = :reopen_on_reply
  #
  # The answer promise: the SLA breach threshold AND the line requesters are
  # shown when they write ("normalmente en menos de 24 h"). One setting, one
  # truth. `at_risk_after` is the earlier, softer warning for the queue.
  #
  # config.reply_within = 24.hours
  # config.at_risk_after = 4.hours
  #
  # Abuse limits, per requester. Both are walls against one person
  # hammering the button, and both are checked before the insert rather
  # than under a lock — so two requests racing about two different things
  # can leave somebody one ticket over the cap. That is deliberate: the
  # alternative locks your own users table on every support ticket, and
  # nobody is harmed by a sixth open case.
  #
  # config.open_rate_limit = { to: 5, within: 1.hour }
  # config.max_open_tickets = 5
  #
  # Whether the desk shows in the requester's inbox before they've written:
  # :always (a "¿Necesitas ayuda?" door), :when_tickets, or :never.
  #
  # config.inbox_entry = :always
  #
  # How new tickets find an agent. 0.1 ships :manual (unassigned, the pool
  # is notified, the first take wins) and ->(ticket) { agent } procs.
  #
  # config.routing = :manual
  #
  # The email channel's two settings, ahead of support_desk 0.2: whether an
  # agent's reply is also emailed to the requester, and whether a case that
  # has been waiting on the requester closes itself.
  #
  # config.mirror_replies_by_email = :when_away   # :always | :when_away | :never
  # config.auto_close_after = nil                 # e.g. 7.days

  # ==========================================================================
  # MORE THAN ONE DESK
  # ==========================================================================
  #
  # Everything above configures the :default desk. Other desks inherit from
  # it and override what they need.
  #
  # config.desk :billing do |desk|
  #   desk.name = "Facturación"
  #   desk.reply_within = 8.hours
  #   desk.agents { User.where(finance: true) }
  # end

  # ==========================================================================
  # EVENTS — the gem emits, your app delivers
  # ==========================================================================
  #
  # Multi-subscriber and error-isolated: a subscriber that raises is
  # reported and the next one still runs. All of them fire after the
  # transition has committed.
  #
  # config.on(:ticket_opened) do |ticket|
  #   TicketActivityNotifier.with(ticket: ticket).deliver(ticket.agents_to_notify)
  # end
  #
  # config.on(:requester_replied) do |ticket, message|
  #   TicketActivityNotifier.with(ticket: ticket, record: message).deliver(ticket.agents_to_notify)
  # end
  #
  # The umbrella event every transition also emits — the audit mirror hook.
  #
  # config.on(:ticket_transitioned) do |ticket, kind, by:, request:, payload:|
  #   AuditLog.log("support_ticket_#{kind}", actor: by, request: request, subject: ticket, **payload)
  # end
  #
  # Keep notification TITLES generic (ticket.notification_title does) and put
  # the detail in the body: a lock screen shouldn't spell out what somebody's
  # support case is about.
end
