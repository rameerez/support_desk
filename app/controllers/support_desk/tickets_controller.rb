# frozen_string_literal: true

module SupportDesk
  # The four screens a person who needs help ever sees: their open cases, the
  # three-step wizard that opens a new one, and the door into the
  # conversation behind a case.
  #
  # The step machine is SupportDesk::Wizard, not this controller: a host that
  # ejects the views, a native app or a JSON API all drive the same steps, so
  # nothing here decides anything the wizard could decide.
  class TicketsController < ApplicationController
    # How many closed cases the collapsed section lists. Support histories
    # only grow, and nobody scrolls a year of them on a phone.
    CLOSED_TICKETS_SHOWN = 20

    before_action :set_wizard, only: %i[new create]
    include Chats::SendRateLimited

    # The ticket page renders chats' thread template, which names chats'
    # routes bare (SupportDesk::ThreadHelper) and asks for these two.
    helper SupportDesk::ThreadHelper
    helper_method :chats_current_messager, :chats_counterpart

    # Their cases: open ones as rows, closed ones folded away, and the door
    # to open another.
    def index
      # `:assignee` because a row says who is on the case when that is a
      # machine, and a name per row is a query per row.
      tickets = current_requester.support_tickets
                                 .includes(:desk, :subject, :assignee, conversation: { last_message: :sender })
      @open_tickets = tickets.not_closed.recent_activity_first.to_a
      @closed_tickets = tickets.closed.newest_first.limit(CLOSED_TICKETS_SHOWN).to_a
      @closed_count = tickets.closed.count
      @unread_counts = unread_counts_for(@open_tickets + @closed_tickets)
      render_screen :index, panel: "support_desk/panel/home"
    end

    # The wizard. One URL, three frames — which one renders is the wizard's
    # answer, never a param we trust. In the launcher's panel, the same step
    # in the panel's one frame.
    def new
      render_wizard
    end

    # The launcher's badge, as the Turbo Stream its own stream would have
    # sent: chats' tray asks for it when that stream may have missed one.
    def badge
      render turbo_stream: turbo_stream.replace(SupportDesk::Launcher::BADGE_ID,
                                                partial: SupportDesk::Launcher::BADGE_PARTIAL,
                                                locals: { count: current_requester.unread_support_count })
    end

    # Open the case and hand the requester straight to the conversation.
    #
    # Two submits land in the same TICKET, because `Ticket.open!` treats a
    # unique-index collision as "you already opened this one" — but they
    # post two opening messages into it, so the form also disables its own
    # button for the length of the submit (`turbo_submits_with`).
    def create
      if message.blank? && files.empty?
        @error = t("support_desk.wizard.message_required")
        return render_wizard(status: :unprocessable_entity)
      end

      ticket = @wizard.open!(message, files: files)
      redirect_to conversation_path_for(ticket)
    rescue ActiveRecord::RecordInvalid => e
      @error = e.record.errors.full_messages.to_sentence
      render_wizard(status: :unprocessable_entity)
    rescue SupportDesk::RateLimited, SupportDesk::TooManyOpenTickets => e
      render_limit_wall(e)
    rescue SupportDesk::InvalidTransition
      # The form was submitted from a step that isn't the composer (a stale
      # tab, a hand-rolled POST): re-render the step they are actually on.
      render_wizard(status: :unprocessable_entity)
    rescue SupportDesk::NotAllowed, SupportDesk::NotSupportable, SupportDesk::NotARequester
      # The subject passed the wizard's check and failed the model's, or this
      # account stopped being able to write between the form and the submit.
      # Same answer as a forged token: 404. "Not yours", "not there" and "not
      # eligible" must look the same from outside.
      raise ActiveRecord::RecordNotFound
    end

    # A stable URL for a case — what an email or a push notification links
    # to. Under `thread_page = :chats` the case is read in the inbox's thread,
    # so this is a redirect and nothing else. Under `:support` it is the page
    # the case is read on: chats' own thread, with its back link leading
    # here rather than to an inbox support is not part of. In the launcher's
    # panel it is always the case, inside the panel, whatever `thread_page`
    # says.
    def show
      ticket = find_ticket
      return render_thread(ticket) if ticket.conversation && (support_panel? || SupportDesk.config.support_thread_page?)

      redirect_to conversation_path_for(ticket)
    end

    # "Prefiero hablar con una persona." The one thing a requester can
    # always do on their own case, and the reason an assistant is allowed to
    # answer at all: nobody is ever trapped in a conversation with a machine.
    #
    # Scoped through their OWN cases, so a foreign id is a 404 and not a
    # refusal that confirms the case exists. Idempotent by the model, so a
    # second press is a second notice and nothing else.
    def request_human
      ticket = find_ticket
      ticket.request_human!(by: current_requester, request: request)
      redirect_to ticket_path(ticket), status: :see_other,
                  notice: t("support_desk.thread.human_requested_notice")
    rescue SupportDesk::Locked, SupportDesk::InvalidTransition
      # A closed case on a desk that locks them, or one the model won't
      # reopen. The case is still theirs to read, so this is the door they
      # came from with the reason on it — never a 500, and never silence.
      redirect_to ticket_path(ticket), status: :see_other, alert: ticket.chat_locked_notice
    end

    private

    def chat_rate_limit_messager = current_requester

    # chats' thread page, rendered here: the same latest page of messages,
    # the same «new messages» line and the same read on open as
    # Chats::ConversationsController#show, for chats' own template. Older
    # pages, the composer and the live updates are chats' endpoints, which
    # reach this conversation through SupportDesk::ConversationAccess.
    def render_thread(ticket)
      @ticket = ticket
      @conversation = chats_conversation(ticket)
      @participant = @conversation.participant_for(current_requester)

      scope = @conversation.messages.includes(:sender, :reactions)
      scope = scope.with_attached_files if scope.respond_to?(:with_attached_files)
      page = scope.recent_first.limit(Chats.config.messages_per_page + 1).to_a
      @more_messages = page.size > Chats.config.messages_per_page
      @messages = page.first(Chats.config.messages_per_page).reverse

      if @participant&.unread?
        @first_unread_id = @participant.unread_messages.where(id: @messages.map(&:id)).oldest_first.pick(:id) ||
                           @messages.first&.id
      end
      # A pointer resting on a link (Turbo's hover prefetch) is not somebody
      # reading the case; the visit that follows reads it. Read through the
      # last message on the page, not merely "now": an acknowledgement pinned
      # one tick after the message it answers may sit just ahead of the clock.
      @participant&.read!(at: [ Time.current, @messages.last&.created_at ].compact.max) unless prefetch_request?

      render_screen :show, panel: "support_desk/panel/case"
    end

    # The wizard's step: the page's three frames, or the panel's one.
    def render_wizard(**options)
      render_screen :new, panel: "support_desk/panel/new", **options
    end

    # The case's conversation, as chats' own endpoints would find it: chats'
    # `find_conversation` on a chats controller bound to this request, so
    # every rule the host or a product gem added there (its lookup scopes, its
    # own `find_conversation`) decides here exactly as at the chats URL. Then
    # it must be this very case's conversation: direct, about this case (the
    # rule Ticket.conversations_of holds the chats lookup to). A 404
    # otherwise, never a hint.
    def chats_conversation(ticket)
      lookup = Chats::ApplicationController.new
      lookup.set_request!(request)
      conversation = lookup.send(:find_conversation, ticket.conversation_id)
      raise ActiveRecord::RecordNotFound unless conversation.direct? &&
                                                conversation.subject_type == ticket.class.polymorphic_name &&
                                                conversation.subject_id.to_s == ticket.id.to_s

      conversation
    end

    def prefetch_request?
      request.headers["X-Sec-Purpose"] == "prefetch" || request.headers["Sec-Purpose"].to_s.include?("prefetch")
    end

    # What chats' thread template asks its controller for.
    def chats_current_messager = current_requester
    def chats_counterpart = @conversation&.counterpart_for(current_requester)

    def set_wizard
      @wizard = SupportDesk::Wizard.new(current_requester, params)
      # A token that is forged, expired, or points at somebody else's record
      # is a 404, never a 403 with a hint: "not yours" and "not there" must
      # look the same from outside.
      raise ActiveRecord::RecordNotFound if @wizard.subject_rejected?
    end

    # By id, or by the reference people read down a phone line ("T-AB12CD").
    # Always through the requester's OWN tickets, so somebody else's case is
    # a 404 rather than a redirect into a conversation they can't read.
    def find_ticket
      scope = current_requester.support_tickets
      reference = SupportDesk::Ticket.normalize_reference(params[:id])

      if params[:id].to_s.upcase.start_with?(SupportDesk::Ticket::REFERENCE_PREFIX)
        scope.find_by!(reference: reference)
      else
        scope.find(params[:id])
      end
    end

    def message
      params[:message].to_s
    end

    def files
      Array(params[:files]).reject(&:blank?)
    end

    # "Ya tienes N conversaciones abiertas" — a wall with the way out on it
    # (their open cases), never a 500 and never a silent failure.
    def render_limit_wall(error)
      @limit_reason = error.is_a?(SupportDesk::TooManyOpenTickets) ? "too_many_open" : "too_fast"
      @open_tickets = current_requester.support_tickets.not_closed
                                       .includes(:desk, :subject, conversation: { last_message: :sender })
                                       .recent_activity_first.to_a
      @unread_counts = unread_counts_for(@open_tickets)
      render_screen :rate_limited, status: :too_many_requests
    end

    # One grouped query for every row's badge (see
    # Chats::Conversation.unread_counts_for).
    def unread_counts_for(tickets)
      ids = tickets.filter_map(&:conversation_id)
      return {} if ids.empty?

      Chats::Conversation.unread_counts_for(current_requester, ids)
    end
  end
end
