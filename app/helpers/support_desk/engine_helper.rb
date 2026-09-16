# frozen_string_literal: true

module SupportDesk
  # View helpers, available BOTH inside the engine's own views and in the
  # HOST app's views (mixed into ActionView via the on_load hook at the
  # bottom of this file — the same pattern chats and moderate use).
  #
  # Two of them are the public API (PRD §4.6):
  #
  #   <%= link_to_support about: @ride %>
  #   <%= support_unread_badge %>
  #
  # The rest are what the bundled views render with, and they stay available
  # after `rails g support_desk:views` so an ejected copy keeps working.
  module EngineHelper
    # Which frame the wizard renders on each of its three steps.
    WIZARD_PARTIALS = { topic: "pick_topic", subject: "pick_thing", compose: "write" }.freeze

    # The door: "¿Necesitas ayuda con esto?" next to a record, or "Contactar
    # con soporte" on its own.
    #
    #   <%= link_to_support about: @ride %>
    #   <%= link_to_support about: @withdrawal, text: "Reportar un problema", class: "btn" %>
    #   <%= link_to_support text: "Contactar con soporte" %>
    #
    # Renders NOTHING when there is no requester, when the record isn't
    # supportable, or when it isn't this requester's to ask about — so it is
    # safe to drop into a shared partial unconditionally. When they already
    # have a case open about it, the door leads to that conversation instead
    # of opening a second one.
    def link_to_support(about: nil, text: nil, **html_options)
      requester = support_desk_requester
      return if requester.nil?
      return if about && !support_subject_available?(about, requester)

      ticket = about && open_support_ticket_about(about, requester)
      if ticket
        link_to text || t("support_desk.doors.existing"), support_thread_path(ticket), **html_options
      else
        link_to text || support_door_text(about), support_desk_routes.new_ticket_path(**support_door_params(about)),
                **html_options
      end
    end

    # The number for a nav item or a tab dock: unread messages across every
    # support conversation this requester has. Renders nothing at zero, so
    # an empty badge never sits in a layout.
    def support_unread_badge(requester = support_desk_requester, css_class: "chats-badge")
      return if requester.nil? || !requester.respond_to?(:unread_support_count)

      count = requester.unread_support_count
      return if count.zero?

      tag.span(count > 99 ? "99+" : count, class: css_class)
    end

    # --- What the bundled views render with -----------------------------------

    # The gem's bundled stylesheet, into the host layout's <head> — where a
    # stylesheet belongs, where `data-turbo-track` means something, and where
    # it loads before the page paints instead of after.
    #
    # Requires `<%= yield :head %>` in the host layout (every Rails app
    # generated this decade has one; add it if yours doesn't). Rendering a
    # <link> mid-body instead would be invalid markup, an inert turbo-track
    # attribute, and a flash of unstyled support screen.
    def support_desk_styles
      content_for(:head) { stylesheet_link_tag "support_desk", "data-turbo-track": "reload" }
    end

    # "Normalmente respondemos en menos de 24 h" for a desk, or nil when the
    # desk promises nothing. The same `config.reply_within` the SLA breaches
    # on — one setting, one truth.
    def support_reply_promise(desk_key = :default)
      within = SupportDesk.config.desk(desk_key).reply_within
      return nil if within.nil?

      t("support_desk.thread.promise", time: SupportDesk::Wizard.humanize_duration(within))
    end

    # The status line under a case in the requester's list: who owes the next
    # word, or that it's over.
    def support_ticket_state(ticket)
      return t("support_desk.tickets.state.closed") if ticket.closed?

      ticket.awaiting_reply? ? t("support_desk.tickets.state.awaiting_reply") : t("support_desk.tickets.state.answered")
    end

    # The partial for the step this wizard is on. The wizard decides which
    # step that is; this only says where the template lives.
    def support_wizard_partial(wizard)
      "support_desk/tickets/#{WIZARD_PARTIALS.fetch(wizard.step)}"
    end

    # Whether the chats inbox should show the "¿Necesitas ayuda? Escríbenos"
    # door for +viewer+: only under `inbox_entry: :always`, and only until
    # they have a case, because from then on chats renders the desk's own
    # grouped row and two entries would be one too many.
    def support_inbox_door?(viewer)
      return false unless viewer.respond_to?(:ask_support!)

      key = viewer.class.try(:support_desk_key) || :default
      return false unless SupportDesk.config.desk(key).inbox_entry == :always

      !viewer.support_tickets.exists?
    end

    # The desk's face. Once the desk has a row it is just another chats
    # messager, so chats draws it; before that (nobody has ever written to
    # it) an initials disc from `config.name`.
    #
    # It never CREATES the desk: this renders on an inbox that may have
    # nothing to do with support, and a page view is not a reason to INSERT.
    def support_desk_avatar(desk_key = :default, css_class: "chats-avatar")
      desk = SupportDesk::Desk.find_by(key: desk_key.to_s)
      return chats_messager_avatar(desk, css_class: css_class) if desk

      name = SupportDesk.config.desk(desk_key).name
      initials = name.to_s.split.first(2).filter_map { |word| word[0] }.join.upcase
      tag.span(initials.presence || "?", class: "#{css_class} chats-avatar--initials", "aria-hidden": true)
    end

    # Where a case is read and answered: its chats conversation. Falls back
    # to the engine's own ticket URL (which redirects to the same place) for
    # the one case that has no conversation yet, so a link is never dead.
    def support_thread_path(ticket)
      return support_desk_routes.ticket_path(ticket) if ticket.conversation.nil? || !respond_to?(:chats_routes)

      chats_routes.conversation_path(ticket.conversation)
    end

    # Engine URL helpers that work from EVERY render context: the mounted
    # proxy (`support_desk.`) inside host views and broadcasts, and the
    # engine's own helpers when the host hasn't mounted it under the default
    # name. Same reasoning as chats' `chats_routes`.
    def support_desk_routes
      respond_to?(:support_desk) ? support_desk : SupportDesk::Engine.routes.url_helpers
    end

    private

    # The current requester in whatever context the helper runs (host page or
    # engine view), resolved through the configured controller method.
    def support_desk_requester
      method_name = SupportDesk.config.current_requester_method
      requester = respond_to?(method_name) ? send(method_name) : nil
      requester if requester.respond_to?(:ask_support!)
    end

    # The requester's open cases, keyed by what they are about, loaded ONCE
    # per request however many doors the page draws. A list screen with a
    # door on every card (CarHey's trip cards) would otherwise pay a query
    # per card, which is the kind of N+1 that only shows up in production.
    #
    # Memoised on the view instance, which is the render's own scope — the
    # same place chats caches its slot lookups.
    def open_support_ticket_about(record, requester)
      @support_open_tickets ||= SupportDesk::Ticket.not_closed
                                                   .where(requester: requester)
                                                   .where.not(subject_id: nil)
                                                   .index_by { |t| [ t.subject_type, t.subject_id.to_s ] }

      @support_open_tickets[[ record.class.polymorphic_name, record.id.to_s ]]
    end

    # Supportable, and theirs to ask about.
    def support_subject_available?(record, requester)
      return false unless record.respond_to?(:supportable?) && record.supportable?

      record.supportable_by?(requester)
    end

    def support_door_text(about)
      return t("support_desk.doors.new") if about.nil?

      t("support_desk.doors.about", subject: about.support_label)
    end

    def support_door_params(about)
      return {} if about.nil?

      { about: SupportDesk::Wizard.sign_subject(about) }
    end
  end
end

# Expose the helpers to the HOST app's views (isolated engines don't share
# helpers automatically). The hook lives HERE, at the bottom of the file that
# defines the constant — not in an engine initializer — so it is
# self-resolving: whenever this file loads, the constant already exists by
# the time the hook can run. See the same note in Chats::EngineHelper.
if defined?(ActiveSupport)
  ActiveSupport.on_load(:action_view) do
    include SupportDesk::EngineHelper
  end
end
