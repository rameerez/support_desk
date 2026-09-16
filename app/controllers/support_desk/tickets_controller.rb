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

    # Their cases: open ones as rows, closed ones folded away, and the door
    # to open another.
    def index
      tickets = current_requester.support_tickets.includes(:desk, :subject, conversation: { last_message: :sender })
      @open_tickets = tickets.not_closed.recent_activity_first.to_a
      @closed_tickets = tickets.closed.newest_first.limit(CLOSED_TICKETS_SHOWN).to_a
      @closed_count = tickets.closed.count
      @unread_counts = unread_counts_for(@open_tickets + @closed_tickets)
    end

    # The wizard. One URL, three frames — which one renders is the wizard's
    # answer, never a param we trust.
    def new
      render :new
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
        return render :new, status: :unprocessable_entity
      end

      ticket = @wizard.open!(message, files: files)
      redirect_to conversation_path_for(ticket)
    rescue ActiveRecord::RecordInvalid => e
      @error = e.record.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    rescue SupportDesk::RateLimited, SupportDesk::TooManyOpenTickets => e
      render_limit_wall(e)
    rescue SupportDesk::InvalidTransition
      # The form was submitted from a step that isn't the composer (a stale
      # tab, a hand-rolled POST): re-render the step they are actually on.
      render :new, status: :unprocessable_entity
    rescue SupportDesk::NotAllowed, SupportDesk::NotSupportable
      # The subject passed the wizard's check and failed the model's. Same
      # answer as a forged token: 404.
      raise ActiveRecord::RecordNotFound
    end

    # A stable URL for a case — what an email or a push notification links
    # to. The case is READ in its conversation, so this is a redirect and
    # nothing else.
    def show
      redirect_to conversation_path_for(find_ticket)
    end

    private

    def chat_rate_limit_messager = current_requester

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
      render :rate_limited, status: :too_many_requests
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
