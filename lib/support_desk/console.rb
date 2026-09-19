# frozen_string_literal: true

require "active_support/concern"

module SupportDesk
  # The agent console as a controller concern: every verb an agent needs,
  # wired to the model, with nothing decided about how it looks.
  #
  #   # config/routes.rb
  #   namespace :madmin do
  #     resources :support_tickets, only: %i[index show new], concerns: :support_console
  #   end
  #
  #   class Madmin::SupportTicketsController < Madmin::ApplicationController
  #     include SupportDesk::Console          # the verbs
  #     include SupportDesk::Console::Index   # optional: @queue, @scope, @tickets
  #
  #     def current_agent = current_user      # or rely on config.current_agent_method
  #   end
  #
  # `index`, `show` and `new` stay yours — they are the UI, and Layer 1
  # (Queue, ContextCard, Timeline, actions_for) is everything they need; the
  # concern fills `new`'s draft and answers the `open_conversation` behind
  # it. What this concern owns is the boring, easy-to-get-wrong half:
  #
  # * <b>Who is asking.</b> `current_agent` must be an eligible agent, or the
  #   request is a 403. `SupportDesk::Current.actor` is set from it, so a
  #   transition anywhere downstream is attributed even when nobody passed
  #   `by:`.
  # * <b>What they may reach.</b> Tickets are found through
  #   `config.visible_desks_for`, so a desk an agent may not work is a plain
  #   404 — never a 403 that confirms the case exists.
  # * <b>Whether the host agrees.</b> `config.authorize_console` is consulted
  #   before every action, including `index`.
  # * <b>Errors are flashes.</b> Every refusal the domain can raise — a
  #   drop-in under `:assignee_only`, a hand-off by somebody who doesn't hold
  #   the ticket, a reply into a locked case — lands in `flash[:alert]` and a
  #   redirect. A console that 500s on a policy is a console nobody trusts.
  #
  # == Paths
  #
  # The verbs have to redirect somewhere, and the same views have to render
  # under `/admin/support` and under `/madmin/support_tickets`. Rather than
  # hard-code either, the concern derives paths from the controller's OWN
  # route (`console_ticket_path`, `console_tickets_path`), so one view set
  # works wherever it is mounted. Override `after_transition_path` to land
  # somewhere else.
  module Console
    extend ActiveSupport::Concern

    # The verbs, in the order the routing concern draws them. ONE table: the
    # routing concern reads it at draw time and `OFFERED_AS` is checked
    # against it, because a verb added in two places is a console that
    # accepts a POST its own Drawer never routed (or the other way round).
    # The four the assistants added sit at the end, in the order a case
    # meets them: decide her proposal, then switch her off or back on.
    MEMBER_VERBS = %i[
      reply take assign hand_off release close reopen note change_topic
      send_draft reject_draft pause_assistant resume_assistant
    ].freeze

    # The verbs that work on the QUEUE rather than on a case, and the HTTP
    # method each one is drawn with. `open_conversation` is the only write
    # here: there is no ticket yet, which is the whole point of it.
    COLLECTION_VERBS = { next: :get, open_conversation: :post }.freeze

    # What 0.1 called the member verbs, kept for a release: a host may have
    # written it into their own routes or their own tests.
    TRANSITIONS = MEMBER_VERBS

    # Actions that work on one ticket, so `set_support_ticket` runs for them.
    # `show` is the host's, but it still wants the ticket found safely.
    MEMBER_ACTIONS = ([ :show ] + MEMBER_VERBS).freeze

    # The two actions that have no ticket: the form, and the send behind it.
    # `authorize_console` is asked about both with a nil ticket.
    CONVERSATION_ACTIONS = %i[new open_conversation].freeze

    # Which entry in `ticket.actions_for(agent)` each verb needs. The
    # console renders exactly what that method returns, so it must accept
    # exactly that too: a POST the UI would never have offered is refused,
    # whether it came from a stale tab, a second agent who got there first,
    # or somebody with curl.
    #
    # `take` and `assign` are both :assign — taking a case is assigning it
    # to yourself, which is the model's vocabulary, not two permissions.
    #
    # `send_draft` is its OWN entry rather than :reply, because
    # `actions_for` offers it only while there is a proposal to send: mapped
    # to :reply it would have accepted a POST naming a draft somebody had
    # already decided about.
    OFFERED_AS = {
      reply: :reply, take: :assign, assign: :assign, hand_off: :hand_off, release: :release,
      close: :close, reopen: :reopen, note: :note, change_topic: :change_topic,
      send_draft: :send_draft, reject_draft: :reject_draft,
      pause_assistant: :pause_assistant, resume_assistant: :resume_assistant
    }.freeze

    # Everything a transition raises because of WHO asked, WHEN, or from WHAT
    # state. All of it is a flash; anything else is a bug and still 500s.
    RESCUED_ERRORS = [
      SupportDesk::NotAllowed,
      SupportDesk::NotTheAssignee,
      SupportDesk::NotAnAgent,
      # Locked is a subclass of InvalidTransition and so already covered.
      # It is listed anyway: a reader shouldn't have to know the hierarchy
      # to know that replying into a locked case is a flash.
      SupportDesk::InvalidTransition,
      SupportDesk::Locked,
      SupportDesk::UnknownTopic,
      SupportDesk::NotSupportable,
      SupportDesk::RateLimited,
      SupportDesk::TooManyOpenTickets,
      # Nobody to write to: a closed account, or a record that was never a
      # requester at all.
      SupportDesk::NotARequester,
      # Everything chats refuses at the write — a blocked pair, a locked
      # conversation, a host policy that says these two may not talk. Its
      # CONFIGURATION error is deliberately not covered by this; see
      # #support_console_rescuable?. Chats is loaded by the spine, so naming
      # it here costs no constant that might not exist.
      Chats::Error
    ].freeze

    # A refusal the console spotted in the REQUEST rather than in the domain:
    # a token that names nothing, a Hash where text belongs, somebody this
    # desk has no way to look up. It carries the locale key its flash reads,
    # and it is deliberately NOT a SupportDesk::Error — nothing outside this
    # concern should be rescuing it.
    class InvalidInput < StandardError
      attr_reader :key

      def initialize(key)
        @key = key.to_s
        super("support_desk.console.errors.#{@key}")
      end
    end

    included do
      before_action :require_support_agent!
      before_action :require_visible_desk!
      before_action :set_support_current_actor
      before_action :set_support_ticket, only: MEMBER_ACTIONS
      before_action :authorize_support_console!
      before_action :require_offered_action!, only: MEMBER_VERBS
      before_action :require_conversation_duty!, only: :open_conversation
      after_action :mark_support_transcript_read, only: :show

      helper_method :current_agent, :support_desk_record, :support_queue, :support_transcript,
                    :console_ticket_path, :console_tickets_path, :console_file_path,
                    :support_conversation_available?, :support_conversation_offered?,
                    :support_conversation_topics, :support_conversation_sendable?,
                    :support_pending_draft, :support_assistant, :support_seen_turn,
                    :support_editing_draft, :support_console_timeline_sentence
    end

    # --- The verbs --------------------------------------------------------------

    # Answer the requester. Under `reply_policy: :anyone` an unheld ticket is
    # taken by whoever answers first; under `:assignee_only` a drop-in is a
    # flash, not a 500.
    def reply
      body = params[:body].to_s
      files = Array(params[:files]).reject(&:blank?)
      return refuse(:blank_message) if body.strip.empty? && files.empty?

      attempt(:replied) { @ticket.reply!(body, by: current_agent, files: files, request: request) }
    end

    # Take an unheld ticket (or one somebody else holds, which is an
    # override — `hand_off` is the polite version).
    def take
      attempt(:taken) { @ticket.assign!(to: current_agent, by: current_agent, request: request) }
    end

    # Give it to somebody else. The target must be in this desk's pool.
    def assign
      agent = support_console_agent
      return refuse(:unknown_agent) if agent.nil?

      attempt(:assigned, agent: support_agent_name(agent)) do
        @ticket.assign!(to: agent, by: current_agent, request: request)
      end
    end

    # `assign` said by the person holding it, with a note for whoever picks
    # it up. Somebody who doesn't hold it gets a flash saying who does.
    def hand_off
      agent = support_console_agent
      return refuse(:unknown_agent) if agent.nil?

      attempt(:handed_off, agent: support_agent_name(agent)) do
        @ticket.hand_off!(to: agent, note: params[:note].presence, by: current_agent, request: request)
      end
    end

    # Put it back in the unassigned pile.
    def release
      attempt(:released) { @ticket.release!(by: current_agent, request: request) }
    end

    def close
      attempt(:closed) { @ticket.close!(by: current_agent, request: request) }
    end

    def reopen
      attempt(:reopened) { @ticket.reopen!(by: current_agent, request: request) }
    end

    # An internal note: timeline and console only, never the conversation.
    def note
      body = params[:body].to_s
      return refuse(:blank_note) if body.strip.empty?

      attempt(:noted) { @ticket.note!(body, by: current_agent, request: request) }
    end

    # Refile the case. Misfiling is normal — the wizard can only offer the
    # tree, and people describe problems in their own words.
    def change_topic
      topic = params[:topic].to_s
      return refuse(:blank_topic) if topic.strip.empty?

      attempt(:topic_changed) { @ticket.change_topic!(to: topic, by: current_agent, request: request) }
    end

    # --- Her proposal, and the switch ------------------------------------------
    #
    # Four verbs, and only one of them is interesting. A draft is written by
    # a machine and SENT BY A PERSON: they read it, they may rewrite it, and
    # the requester sees their signature on it. Everything here exists to
    # make that reading real — which is why a send carries the turn the page
    # was rendered with, and why a mismatch comes back as the same screen
    # rather than as a redirect that throws the reviewer's edit away.

    # Send the proposal, verbatim or edited.
    def send_draft
      draft = support_reviewable_draft
      return if draft.nil?

      seen = params[:seen_turn]
      return refuse(:invalid_input) unless seen.is_a?(String) && seen.present?

      body = params[:body].is_a?(String) ? params[:body] : nil
      # The model refuses an edit that is blank with no attachment, and it
      # refuses it with an ArgumentError — a bug in the caller, not a flash.
      # So the console asks the same question first, in the words an agent
      # needs: an empty box is "write something", never "descártala".
      return refuse(:blank_message) if body && body.strip.empty? && !draft.files_attached?

      draft.send!(by: current_agent, seen_turn: seen, body: body, request: request)
      flash[:notice] = support_console_t("flashes.draft_sent")
      respond_to_transition
    rescue SupportDesk::StaleTurn
      refuse_stale_draft
    rescue StandardError => error
      raise unless support_console_rescuable?(error)

      flash[:alert] = support_console_error_message(error)
      respond_to_transition
    end

    # Throw it away, with a reason worth reading later: the rejections are
    # what tell a host whether the assistant is ready for a higher level.
    def reject_draft
      draft = support_reviewable_draft
      return if draft.nil?

      attempt(:draft_rejected) do
        draft.reject!(by: current_agent, reason: support_console_text(:reason), request: request)
      end
    end

    # Switch her off on THIS case: a delicate conversation, a customer who
    # has had enough, a thread somebody wants to handle themselves.
    def pause_assistant
      attempt(:assistant_paused) do
        @ticket.pause_assistant!(by: current_agent, reason: support_console_text(:reason), request: request)
      end
    end

    # Let her back in on this case.
    def resume_assistant
      attempt(:assistant_resumed) { @ticket.resume_assistant!(by: current_agent, request: request) }
    end

    # The form for writing to somebody who hasn't written to us — "Escribir
    # a alguien". Renders with whatever the caller supplied: a requester
    # GlobalID from one of your own pages (a user's admin screen, a ride),
    # a subject to be about, a topic. Blank is an empty form; a token that
    # names nothing is the same refusal here as it is on the send, because a
    # form that quietly drops the person it was opened for is worse than one
    # that says it couldn't find them.
    def new
      assign_conversation_draft
    rescue StandardError => error
      raise unless support_console_rescuable?(error)

      refuse_conversation(error)
    end

    # Send it. One case either way: a new one when this person has nothing
    # open that covers it, an ordinary reply into the one they do — under
    # this desk's reply policy, and only if the host still says this agent
    # may answer THAT case.
    def open_conversation
      assign_conversation_draft
      ticket = SupportDesk::Ticket.open_or_reply!(**conversation_arguments)

      @ticket = ticket
      redirect_to after_transition_path(ticket), status: :see_other,
                  notice: support_console_t("flashes.message_sent",
                                            requester: Chats.display_name_for(@requester))
    rescue StandardError => error
      raise unless support_console_rescuable?(error)

      refuse_conversation(error)
    end

    # The most urgent thing this agent should be looking at. The whole
    # "work the queue" loop is this one button.
    def next
      ticket = support_queue.next
      return redirect_to(console_tickets_path, notice: support_console_t("flashes.queue_empty")) if ticket.nil?

      redirect_to console_ticket_path(ticket)
    end

    # --- Paths ------------------------------------------------------------------

    # This console's path to one ticket — derived from the controller's own
    # route, so the same view renders under any mount point or namespace.
    def console_ticket_path(ticket, action = :show, **params)
      url_for(controller: "/#{controller_path}", action: action, id: ticket.to_param,
              only_path: true, **params)
    end

    # This console's collection path (`:index` by default, `:next` for the
    # "work the queue" button).
    def console_tickets_path(action = :index, **params)
      url_for(controller: "/#{controller_path}", action: action, only_path: true, **params)
    end

    # Where a verb lands when it's done. Override to go back to the queue,
    # or on to `next`.
    def after_transition_path(ticket) = console_ticket_path(ticket)

    # A URL for a message attachment that resolves the same in both places
    # this console renders. Inside a mounted engine a bare `url_for(blob)`
    # looks for Active Storage's routes in the ENGINE's route set and blows
    # up; the main app's helpers are right either way.
    def console_file_path(file)
      Rails.application.routes.url_helpers.rails_blob_path(file, only_path: true)
    end

    # The case as the requester experienced it: every visible message,
    # oldest first, with senders, authors and attachments preloaded.
    # Override to paginate a long one.
    def support_transcript(ticket = @ticket)
      scope = ticket.messages.visible.oldest_first.includes(:sender, :author)
      scope = scope.with_attached_files if scope.respond_to?(:with_attached_files)
      scope.load
      @support_read_through = scope.last&.created_at if ticket == @ticket
      scope
    end

    # The proposal waiting on this case, or nil. What `show` renders the
    # draft card from, and what the composer's edit mode is about.
    def support_pending_draft(ticket = @ticket)
      ticket&.pending_draft
    end

    # This desk's assistant, or nil. A view asks it to decide whether there
    # is a switch to draw at all — never to decide what may be pressed.
    def support_assistant(ticket = @ticket)
      ticket&.assistant
    end

    # The turn the page is being rendered with, which every send carries
    # back. A case that has never been touched still has one, so this is
    # never nil and the form never has an empty hidden field.
    def support_seen_turn(ticket = @ticket)
      ticket&.assistant_turn
    end

    # The draft the composer is EDITING: the reviewer pressed "Editar"
    # (`?compose=reply&draft=ID`), or a stale send came back as this screen
    # with their text still in it. Nil unless it names the pending proposal
    # AND this agent is offered the send — a composer in edit mode with no
    # way to submit is worse than no edit mode at all.
    def support_editing_draft(ticket = @ticket)
      draft = support_pending_draft(ticket)
      return nil if draft.nil?
      return nil unless support_offered_actions(ticket).include?(:send_draft)

      named = [ params[:draft], params[:draft_id] ].detect { |value| value.is_a?(String) && value.present? }
      named == draft.id.to_s ? draft : nil
    end

    # One line for the timeline kinds the assistants added — "Lucía envió la
    # propuesta de Rose" — from the event's own payload. Nil for everything
    # else, so the partial falls back to the label-and-actor shape 0.2 had.
    #
    # It lives here rather than in the partial because the sentence is COPY:
    # an ejected view must not have to carry a `case` over event kinds to
    # keep saying the right thing in Spanish.
    def support_console_timeline_sentence(entry, actor_name = nil)
      return nil unless entry.event?

      payload = entry.event.payload.is_a?(Hash) ? entry.event.payload : {}
      assistant = support_console_assistant_name(payload["assistant"])

      case entry.kind
      when :escalated
        support_console_t("timeline.escalated", actor: actor_name,
                                                reason: support_console_reason_word(payload["reason"]))
      when :human_requested then support_console_t("timeline.human_requested")
      when :assistant_paused then support_console_t("timeline.assistant_paused", actor: actor_name)
      when :assistant_resumed then support_console_t("timeline.assistant_resumed", actor: actor_name)
      when :draft_sent
        support_console_t("timeline.draft_sent#{"_edited" if payload["edited"]}",
                          actor: actor_name, assistant: assistant)
      when :draft_rejected
        support_console_t("timeline.draft_rejected", actor: actor_name, assistant: assistant)
      when :assistant_withheld
        support_console_t("timeline.assistant_withheld", assistant: assistant,
                                                         reason: support_console_withheld_word(payload["reason"]))
      end
    end

    # The default queue tab and the tickets behind it, for hosts that want
    # the obvious index. Entirely optional — everything it does is three
    # lines of Layer 1.
    #
    #   class Madmin::SupportTicketsController < Madmin::ApplicationController
    #     include SupportDesk::Console
    #     include SupportDesk::Console::Index
    #   end
    module Index
      extend ActiveSupport::Concern

      included do
        helper_method :support_tickets_per_page
      end

      # `@queue`, `@scope` and `@tickets` — the queue, the tab being looked
      # at, and its rows.
      def index
        @queue = support_queue
        @scope = support_queue_scope
        @tickets = support_queue_tickets
      end

      private

      # `?tab=` when it names a real tab, else the tab an agent would have
      # opened anyway: what needs an answer, or their own pile when nothing
      # does.
      def support_queue_scope
        requested = params[:tab].presence&.to_sym
        return requested if SupportDesk::Queue::TABS.include?(requested)

        support_queue.awaiting.exists? ? :awaiting : :mine
      end

      # The rows, with everything a row renders already loaded.
      #
      # `:subject` is the one that is easy to forget and expensive to miss:
      # every row prints `ticket.label`, which falls through to the
      # subject's own `support_label`, so leaving it out is a SELECT per row
      # that no test notices until somebody counts.
      def support_queue_tickets
        support_queue.scope(@scope)
                     .includes(:requester, :assignee, :desk, :subject, :opened_by, :pending_draft,
                               conversation: { last_message: %i[sender author] })
                     .limit(support_tickets_per_page)
      end

      # How many rows the index shows. Override, or paginate the relation
      # with whatever your app already uses.
      def support_tickets_per_page = 50
    end

    # --- Writing first ------------------------------------------------------------
    #
    # Two overridable seams, and their contract:
    #
    # * `support_conversation_requester` returns the person this conversation
    #   is FOR, or nil when nothing was supplied. It NEVER returns somebody
    #   other than the one that was asked for: a supplied GlobalID is
    #   authoritative, and a bad one is a refusal
    #   (`raise InvalidInput, :invalid_requester`), never a silent fallback
    #   to the typed query.
    # * `support_conversation_subject` returns what the case is about, or
    #   nil when nothing was supplied; a supplied token that doesn't resolve,
    #   or resolves to something this requester may not talk about, is
    #   `raise InvalidInput, :invalid_subject`.
    #
    # Both are looked up inside the classes that declared themselves
    # (`SupportDesk.requester_classes`, `.supportable_classes`) — a raw
    # GlobalID is an identifier, never permission to call `find` on whatever
    # class it names. A multi-tenant host narrows BOTH ways in, because
    # `config.find_requester` only guards the typed one:
    #
    #   def support_conversation_requester
    #     found = super
    #     return nil if found.nil?
    #     raise SupportDesk::Console::InvalidInput, :invalid_requester unless
    #       found.account_id == current_agent.account_id
    #
    #     found
    #   end
    #
    # (The model checks eligibility on its own either way — see
    # `Ticket.open!` — so an override that forgets is a narrower door, never
    # a wider one.)

    # The person this conversation is for, from a GlobalID one of your own
    # pages handed over, or from what an agent typed into the form.
    def support_conversation_requester
      token = conversation_param(:requester)
      return locate_conversation_record(token, SupportDesk.requester_classes, :invalid_requester) if token.present?
      return nil if @requester_query.blank?

      finder = support_desk_record.config.find_requester
      raise InvalidInput, :no_requester_lookup if finder.nil?

      found = finder.call(@requester_query)
      raise InvalidInput, :unknown_requester if found.nil?
      raise InvalidInput, :invalid_requester unless SupportDesk.requester_class?(found.class)

      found
    end

    # What the case is about, when the page that opened the form knew.
    def support_conversation_subject
      token = conversation_param(:about)
      return nil if token.blank?

      subject = locate_conversation_record(token, SupportDesk.supportable_classes, :invalid_subject)
      # Checked here so the form can't show a card for something this person
      # may not talk about, and checked AGAIN by the model at the write.
      raise InvalidInput, :invalid_subject unless @requester && subject.supportable_by?(@requester)

      subject
    end

    private

    # Everything the form renders, set BEFORE anything can fail: a refusal
    # has to come back with the draft still in it, or an agent retypes their
    # message every time they mistype an email.
    def assign_conversation_draft
      @requester = nil
      @about = nil
      # Capture every independently valid field before any validation raises.
      @requester_query, @topic, @body = %i[requester_query topic body].map do |name|
        params[name].is_a?(String) ? params[name] : ""
      end
      @topic = @topic.presence
      @files = []

      @requester = support_conversation_requester
      @about = support_conversation_subject
      # A supplied topic wins; a subject's own topic is the obvious default.
      @topic ||= @about&.support_topic
      %i[requester_query topic body].each { |name| conversation_param(name) }
      validate_conversation_desk!
      @conversation_requester_unavailable = @requester.present?
      SupportDesk::Ticket.ensure_requester!(@requester) if @requester
      @conversation_requester_unavailable = false
      @files = conversation_files
    end

    def validate_conversation_desk!
      return unless params.key?(:desk)

      key = params[:desk]
      return if key.is_a?(String) && support_visible_desks.any? { |desk| desk.key.to_s == key }

      @invalid_conversation_desk = true
      raise InvalidInput, :invalid_input
    end

    # Validate transport shapes here; MIME/size/count policy stays on Message.
    def conversation_files
      files = params[:files]
      return [] if files.nil?
      raise InvalidInput, :invalid_input unless files.is_a?(Array)

      files.reject { |file| file.nil? || file == "" }.map do |file|
        case file
        when ActionDispatch::Http::UploadedFile then file
        when String
          raise InvalidInput, :invalid_input unless defined?(ActiveStorage::Blob)

          begin
            ActiveStorage::Blob.find_signed!(file)
          rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
            raise InvalidInput, :invalid_input
          end
        else raise InvalidInput, :invalid_input
        end
      end
    end

    def conversation_arguments
      raise InvalidInput, :unknown_requester if @requester.nil?
      # The same answer the member `reply` action gives, for the same
      # mistake. The MODEL refuses a blank staff message too (and rolls the
      # case back with it), but "Escribe algo antes de enviar" is what an
      # agent needs to read, not a validation error about a message body.
      raise InvalidInput, :blank_message if @body.strip.empty? && @files.empty?
      # A dual-role account (an admin who is also a customer) writing to
      # themselves is ambiguous: the low-level API would read it as them
      # asking for help, which is not what this form is for.
      if SupportDesk::Ticket.same_actor?(@requester, current_agent)
        raise InvalidInput, :writing_to_yourself
      end

      {
        requester: @requester, by: current_agent, message: @body, about: @about, topic: @topic,
        files: @files, via: :in_app, desk: support_desk_record, request: request,
        requester_role: @requester.class.support_desk_requester_options[:as],
        authorize_reuse: method(:authorize_conversation_reuse)
      }
    end

    # Run under the REUSED case's row lock, before the reply policy has done
    # anything: a host may let this agent write to this person and still
    # refuse them this particular case, and the answer has to be the same one
    # the member `reply` action would have given. Raising rolls the whole
    # operation back.
    def authorize_conversation_reuse(ticket)
      @ticket = ticket
      return if SupportDesk.config.console_authorized?(current_agent, ticket, :reply) &&
                ticket.actions_for(current_agent).include?(:reply)

      raise SupportDesk::NotAllowed,
            "#{current_agent.class}##{current_agent.id} may not reply to ticket #{ticket.reference}"
    end

    # Text fields are text. A Hash or an Array where a string belongs is a
    # crafted request, not something to `.to_s` and then look up.
    def conversation_param(name)
      value = params[name]
      return "" if value.nil?
      raise InvalidInput, :invalid_input unless value.is_a?(String)

      value
    end

    # A GlobalID is an identifier, not an authorization: it resolves only
    # inside the classes that declared themselves, only for this app, and a
    # token that is malformed, foreign, out of that set or pointing at a row
    # that is gone is one refusal — never a different target.
    def locate_conversation_record(token, allowed, refusal)
      gid = GlobalID.parse(token)
      raise InvalidInput, refusal if gid.nil? || gid.app.to_s != GlobalID.app.to_s

      # safe_constantize ignores missing token constants, but propagates bugs
      # inside an autoload. The host finder runs outside that boundary.
      model = gid.model_name.safe_constantize
      raise InvalidInput, refusal unless model.is_a?(Class) && allowed.any? { |klass| model <= klass }

      GlobalID::Locator.locate(gid, only: allowed) || raise(InvalidInput, refusal)
    rescue ActiveRecord::RecordNotFound, GlobalID::Locator::InvalidModelIdError
      # A class name nothing answers to, an id the model can't read, a row
      # that is gone: the same bad token in the same field.
      raise InvalidInput, refusal
    end

    # Off duty is off duty on both surfaces: `actions_for` gives an off-duty
    # agent nothing that speaks to a requester, and neither does this.
    def require_conversation_duty!
      return if support_conversation_available?

      assign_conversation_draft
      flash.now[:alert] = support_console_t("errors.off_duty")
      render :new, formats: [ :html ], status: :unprocessable_entity
    rescue StandardError => error
      raise unless support_console_rescuable?(error)

      refuse_conversation(error)
    end

    # Whether this agent may send from the form at all — what the form reads
    # to disable its own button rather than offering one that only ever 422s.
    def support_conversation_available?
      !current_agent.respond_to?(:on_duty?) || current_agent.on_duty?
    end

    def support_conversation_sendable?
      support_conversation_available? && !@invalid_conversation_desk && !@conversation_requester_unavailable
    end

    # Whether to show the door on the queue at all: on duty, and the host's
    # policy says so. Both are asked again at the form and at the send — this
    # is what keeps the queue from offering a button that only refuses.
    def support_conversation_offered?
      support_conversation_available? &&
        SupportDesk.config.console_authorized?(current_agent, nil, :open_conversation)
    end

    # The topics a case can be opened onto from here: the leaves somebody
    # can write freely under. A subject brings its own topic with it, so
    # this is the picker for everything else.
    def support_conversation_topics
      support_desk_record.config.topics.leaves.select(&:free_form?)
    end

    # A handled refusal: the form again, with everything the agent typed
    # still in it, and the reason on top. 422 rather than a redirect for
    # HTML and Turbo alike — a stream refresh would throw the draft away.
    def refuse_conversation(error)
      flash.now[:alert] = support_conversation_error_message(error)
      render :new, formats: [ :html ], status: :unprocessable_entity
    end

    def support_conversation_error_message(error)
      return support_console_t("errors.#{error.key}") if error.is_a?(InvalidInput)

      support_console_error_message(error)
    end

    def mark_support_transcript_read
      return unless response.successful? && @support_read_through

      @ticket.conversation.participant_for(@ticket.desk)&.read!(at: @support_read_through)
    end

    # --- Who is asking ------------------------------------------------------------

    # The person answering. Define `current_agent` in your controller, or
    # point `config.current_agent_method` at the method you already have.
    def current_agent
      return @current_agent if defined?(@current_agent)

      method_name = SupportDesk.config.current_agent_method
      unless respond_to?(method_name, true)
        raise SupportDesk::ConfigurationError,
              "support_desk can't find ##{method_name} on #{self.class.name}. Define `current_agent` in " \
              "your console controller, or set config.current_agent_method to the method that returns " \
              "the logged-in agent."
      end

      @current_agent = send(method_name)
    end

    def require_support_agent!
      agent = current_agent
      return if agent.respond_to?(:support_agent?) && agent.support_agent?

      support_console_forbidden
    end

    # Every transition takes `by:` explicitly; this is the belt for anything
    # a host calls downstream without one (a job kicked off from an event,
    # a callback in their own model).
    def set_support_current_actor
      SupportDesk::Current.actor = current_agent
      SupportDesk::Current.request = request
    end

    def authorize_support_console!
      return if SupportDesk.config.console_authorized?(current_agent, @ticket, action_name.to_sym)

      support_console_forbidden
    end

    # Refuse a verb the console wouldn't have offered. Without this the UI
    # and the endpoint can disagree — `actions_for` drops :reply on a closed
    # case, but the model happily posts one, so the composer vanished while
    # the POST behind it still flashed success.
    def require_offered_action!
      offered = @ticket.actions_for(current_agent)
      return if offered.include?(OFFERED_AS.fetch(action_name.to_sym))

      flash[:alert] = support_console_t("errors.#{unavailable_reason}",
                                        holder: support_console_holder,
                                        status: support_draft_status_word(support_named_draft))
      respond_to_transition
    end

    # Why the button wasn't there, in the words that help most: the case is
    # done, somebody else has it, or nobody does and this desk wants it
    # taken first.
    def unavailable_reason
      return "closed_case" if @ticket.closed?
      return draft_unavailable_reason if %i[send_draft reject_draft].include?(action_name.to_sym)
      return "unavailable_action" unless %i[reply hand_off].include?(action_name.to_sym)
      return "take_it_first" if @ticket.unassigned?

      "held_by_somebody_else"
    end

    # Pressing the same button twice is the common way to get here, and
    # "there is no proposal" is the wrong thing to read after sending one.
    # The row the request names is the whole answer: still there and already
    # decided, or gone.
    def draft_unavailable_reason
      named = support_named_draft
      return "draft_already_reviewed" if named && !named.pending?
      return "no_pending_draft" if @ticket.pending_draft.nil?

      "unavailable_action"
    end

    # Who has the case, for a refusal that names them.
    def support_console_holder
      @ticket&.assignee&.try(:support_agent_name) || support_console_t("assignment.nobody")
    end

    # A 403 that says why, in the host's locale. Override for a prettier one.
    # A refusal the agent can actually see.
    #
    # A 403 with a plain-text body is the right answer to a GET and the
    # wrong one to a Turbo form submission: Turbo only renders an error
    # response it can read as HTML, so a text/plain 403 is dropped on the
    # floor and the button looks broken rather than refused. The stream
    # branch carries a real flash and refreshes, so the agent reads why.
    def support_console_forbidden
      respond_to do |format|
        format.turbo_stream do
          flash[:alert] = support_console_t("errors.forbidden")
          render_support_console_refresh
        end
        format.any { render plain: support_console_t("errors.forbidden"), status: :forbidden }
      end
    end

    # --- What they may reach --------------------------------------------------------

    def set_support_ticket
      @ticket = support_visible_tickets.find(params[:id])
    end

    # Tickets on the desks this agent may work. A ticket outside them is
    # `ActiveRecord::RecordNotFound` — a 404, which is the honest answer.
    def support_visible_tickets
      SupportDesk::Ticket.where(desk: support_visible_desks)
    end

    # The desks this agent may work, asked once per request. EVERYTHING the
    # console reaches for is scoped through this — the ticket, the queue,
    # the tab counts, the badge and `next` — because scoping only the member
    # actions leaves the index answering 200 with a reference, a requester's
    # name and a preview on it.
    def support_visible_desks
      @support_visible_desks ||= SupportDesk.config.desks_visible_to(current_agent).to_a
    end

    # Nothing to work is not the same as "this case is none of your
    # business": there is no case yet. A 403 says so, and it stops `?desk=`
    # from being a way to ask about desks that were never on offer.
    def require_visible_desk!
      support_console_forbidden if support_visible_desks.empty?
    end

    # The desk this console is working. `?desk=billing` switches between
    # them on a multi-desk host — but only among the ones this agent may
    # see; a key outside that set quietly falls back to the first visible
    # desk rather than confirming that it exists.
    def support_desk_record
      return @support_desk_record if defined?(@support_desk_record)

      # A desk key is text. A Hash or an Array here is not a desk anybody has
      # — it is a crafted parameter — and every console screen reads this, so
      # it answers the way an unknown key does (the first visible desk)
      # rather than taking the whole console down with a NoMethodError.
      requested = params[:desk]
      requested = requested.is_a?(String) ? requested.presence&.to_sym : nil
      @support_desk_record =
        (requested && support_visible_desks.detect { |desk| desk.key.to_sym == requested }) ||
        support_visible_desks.first
    end

    def support_queue
      @support_queue ||= SupportDesk::Queue.for(current_agent, desk: support_desk_record)
    end

    # The assign / hand-off target, resolved inside the pool of the TICKET's
    # desk — never the one `?desk=` names. Those are different desks the
    # moment a host has two, and reading the parameter let a billing agent
    # be assigned to a case on another desk entirely.
    # Values are `SupportDesk.actor_key(agent)` — a GlobalID, which says
    # WHICH CLASS as well as which row. The pool is people and the desk's
    # assistant, and their ids are drawn from different tables: a picker
    # posting a bare "1" could mean either of them, and "assign the case to
    # the machine" is not a mistake to make on a coin flip.
    #
    # A bare id still resolves, because a host may have written one into
    # their own form — but only while exactly one member of the pool answers
    # to it. Two matches is a refusal, not a guess.
    def support_console_agent(id = params[:agent_id])
      return nil if id.blank?

      key = id.to_s
      pool = @ticket.desk.agents
      exact = pool.detect { |agent| SupportDesk.actor_key(agent) == key }
      return exact if exact

      matches = pool.select { |agent| agent.id.to_s == key }
      matches.one? ? matches.first : nil
    end

    # --- The proposal a request names -------------------------------------------

    # The draft this request names, in ANY status. Deliberately not
    # `drafts.pending`: a second submit of the same button has to be able to
    # read "ya se envió" instead of "no hay ninguna propuesta", and only the
    # row itself knows which.
    def support_console_draft
      raise InvalidInput, :invalid_input unless params[:draft_id].is_a?(String)

      support_named_draft
    end

    # The same lookup for the REFUSALS, which run before the action and must
    # never raise: a crafted `draft_id` on a case with nothing pending is a
    # flash, not a 500.
    def support_named_draft
      return @support_named_draft if defined?(@support_named_draft)

      id = params[:draft_id]
      @support_named_draft = (@ticket.drafts.find_by(id: id) if id.is_a?(String) && id.present?)
    rescue ActiveRecord::StatementInvalid
      # A uuid-keyed host: an id that isn't one is an id nothing has.
      @support_named_draft = nil
    end

    # The draft a decision may be made about, or nil with the refusal
    # already rendered.
    def support_reviewable_draft
      draft = support_console_draft
      if draft.nil?
        refuse(:unknown_draft)
      elsif !draft.pending?
        refuse(:draft_already_reviewed, status: support_draft_status_word(draft))
      else
        return draft
      end
      nil
    rescue InvalidInput => error
      refuse(error.key)
      nil
    end

    # What happened to a draft, as the word the flash reads: "ya se envió",
    # "ya se descartó". Never the English status — a Spanish desk reading
    # "ya se sent" is the bug this map exists to stop.
    def support_draft_status_word(draft)
      return nil if draft.nil?

      support_console_t("draft.statuses.#{draft.status}", default: draft.status)
    end

    # The case moved between the render and the submit. A redirect here
    # would throw away whatever the reviewer typed, so this is the SAME
    # screen again with a 422: their text still in the composer, the CURRENT
    # turn in the form, and the reason on top. There is no "send anyway" —
    # reading the case again is the whole point.
    def refuse_stale_draft
      @ticket.reload
      flash.now[:alert] = support_console_t("errors.stale_turn")
      rerender_support_case
    end

    # The case screen again, as the host renders it: their own `show` runs,
    # so whatever it sets up is set up, and the two things every bundled
    # view needs are filled in when it didn't.
    def rerender_support_case(status: :unprocessable_entity)
      show if respond_to?(:show)
      @actions ||= @ticket.actions_for(current_agent)
      @context_card ||= @ticket.context_card
      render :show, formats: [ :html ], status: status unless performed?
    end

    # The buttons this agent is offered on +ticket+, asked once per render.
    # `show` usually set them already; a 422 re-render may not have.
    def support_offered_actions(ticket = @ticket)
      return @actions if ticket == @ticket && @actions

      ticket.actions_for(current_agent)
    end

    # A free-text field a verb takes: text, or nothing. A Hash where a
    # reason belongs is a crafted request, and `.to_s` on it would be
    # written into an event payload forever.
    def support_console_text(name)
      value = params[name]
      value.is_a?(String) ? value.presence : nil
    end

    def support_agent_name(agent)
      agent.try(:support_agent_name) || agent.to_s
    end

    # --- Running a verb --------------------------------------------------------------

    # Run a transition, turn every refusal into a flash, and answer in the
    # format that was asked for. The one place a console action can end.
    def attempt(outcome, **interpolations)
      yield
      flash[:notice] = support_console_t("flashes.#{outcome}", **interpolations)
      respond_to_transition
    rescue StandardError => error
      raise unless support_console_rescuable?(error)

      flash[:alert] = support_console_error_message(error)
      respond_to_transition
    end

    # A refusal the console spotted before the model was asked (an empty
    # message, an agent who isn't in the pool).
    def refuse(reason, **interpolations)
      flash[:alert] = support_console_t("errors.#{reason}", **interpolations)
      respond_to_transition
    end

    def respond_to_transition
      respond_to do |format|
        format.turbo_stream { render_support_console_refresh }
        format.any { redirect_to after_transition_path(@ticket) }
      end
    end

    # A Turbo 8 page refresh (morph), written as a raw tag rather than
    # `turbo_stream.refresh` so the gem needs no turbo-rails version floor.
    # The flash is a real flash, so it survives the refetch.
    #
    # `render body:` rather than `render html:`: the html renderer forces
    # text/html and quietly ignores `content_type:`, and a stream Turbo
    # doesn't recognise as a stream is a stream Turbo throws away.
    def render_support_console_refresh
      render body: '<turbo-stream action="refresh"></turbo-stream>',
             content_type: "text/vnd.turbo-stream.html"
    end

    def support_console_rescuable?(error)
      # A chats CONFIGURATION error is a bug in the host's wiring, not a
      # refusal an agent can do anything about, and it is a Chats::Error —
      # so it has to be taken back out before the base class goes in.
      return false if error.is_a?(Chats::ConfigurationError)
      return true if error.is_a?(InvalidInput)
      return true if RESCUED_ERRORS.any? { |klass| error.is_a?(klass) }
      # A RUNTIME check on purpose: `require "support_desk"` in a fresh
      # process does not load ActiveRecord (chats is required, ActiveRecord
      # is not), and naming the constant in RESCUED_ERRORS would break that.
      return true if defined?(ActiveRecord::RecordInvalid) && error.is_a?(ActiveRecord::RecordInvalid)

      false
    end

    # A translated sentence, never the exception's own text. The model
    # raises in English on purpose — those messages are written for whoever
    # is reading a stack trace — so passing one straight into a flash meant
    # a Spanish desk read "doesn't hold ticket T-AB12CD". `holder` carries
    # the one detail worth keeping, and the console knows it without having
    # to parse the error.
    # The key is the error's own name (`NotTheAssignee` →
    # "not_the_assignee"), so a new error needs copy and nothing else — and a
    # host that overrode one of these keys keeps its wording, because the
    # names are the ones the old hand-written table used.
    def support_console_error_message(error)
      key = error.class.name.demodulize.underscore
      support_console_t("errors.#{key}", detail: error.message, holder: support_console_holder,
                                         default: :"support_desk.console.errors.generic")
    end

    # Who proposed it, in a word. The payloads carry a key on one kind and
    # an actor key on another, and this desk's own assistant answers to
    # both; anything else is history (a host swapped assistants), so the
    # readable half of the token stands in rather than a GlobalID nobody
    # can read.
    def support_console_assistant_name(token)
      token = token.to_s
      assistant = @ticket&.assistant
      return assistant.name if assistant && [ assistant.key.to_s, SupportDesk.actor_key(assistant) ].include?(token)
      return token.humanize if token.match?(/\A[a-z0-9_]+\z/i)

      @ticket&.desk&.name.to_s
    end

    # Why a case was handed to a person, as a sentence rather than as the
    # token the model writes. A reason a host's own harness invented falls
    # back to itself — a strange word in the timeline beats no word at all.
    def support_console_reason_word(reason)
      support_console_t("escalation_reasons.#{reason}", default: reason.to_s.humanize)
    end

    # Why she said nothing.
    def support_console_withheld_word(reason)
      support_console_t("withheld_reasons.#{reason}", default: reason.to_s.humanize)
    end

    def support_console_t(key, **interpolations)
      I18n.t("support_desk.console.#{key}", **interpolations)
    end
  end
end
