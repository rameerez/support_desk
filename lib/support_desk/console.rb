# frozen_string_literal: true

require "active_support/concern"

module SupportDesk
  # The agent console as a controller concern: every verb an agent needs,
  # wired to the model, with nothing decided about how it looks.
  #
  #   # config/routes.rb
  #   namespace :madmin do
  #     resources :support_tickets, only: %i[index show], concerns: :support_console
  #   end
  #
  #   class Madmin::SupportTicketsController < Madmin::ApplicationController
  #     include SupportDesk::Console          # the verbs
  #     include SupportDesk::Console::Index   # optional: @queue, @scope, @tickets
  #
  #     def current_agent = current_user      # or rely on config.current_agent_method
  #   end
  #
  # `index` and `show` stay yours — they are the UI, and Layer 1 (Queue,
  # ContextCard, Timeline, actions_for) is everything they need. What this
  # concern owns is the boring, easy-to-get-wrong half:
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

    # The verbs, in the order the routing concern draws them.
    TRANSITIONS = %i[reply take assign hand_off release close reopen note change_topic].freeze

    # Actions that work on one ticket, so `set_support_ticket` runs for them.
    # `show` is the host's, but it still wants the ticket found safely.
    MEMBER_ACTIONS = ([ :show ] + TRANSITIONS).freeze

    # Which entry in `ticket.actions_for(agent)` each verb needs. The
    # console renders exactly what that method returns, so it must accept
    # exactly that too: a POST the UI would never have offered is refused,
    # whether it came from a stale tab, a second agent who got there first,
    # or somebody with curl.
    #
    # `take` and `assign` are both :assign — taking a case is assigning it
    # to yourself, which is the model's vocabulary, not two permissions.
    OFFERED_AS = {
      reply: :reply, take: :assign, assign: :assign, hand_off: :hand_off, release: :release,
      close: :close, reopen: :reopen, note: :note, change_topic: :change_topic
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
      SupportDesk::TooManyOpenTickets
    ].freeze

    # The flash an error translates into. Unlisted ones fall back to
    # `support_desk.console.errors.generic`.
    ERROR_KEYS = {
      "SupportDesk::NotAllowed" => "not_allowed",
      "SupportDesk::NotTheAssignee" => "not_the_assignee",
      "SupportDesk::NotAnAgent" => "not_an_agent",
      "SupportDesk::InvalidTransition" => "invalid_transition",
      "SupportDesk::Locked" => "locked",
      "SupportDesk::UnknownTopic" => "unknown_topic"
    }.freeze

    included do
      before_action :require_support_agent!
      before_action :require_visible_desk!
      before_action :set_support_current_actor
      before_action :set_support_ticket, only: MEMBER_ACTIONS
      before_action :authorize_support_console!
      before_action :require_offered_action!, only: TRANSITIONS
      after_action :mark_support_transcript_read, only: :show

      helper_method :current_agent, :support_desk_record, :support_queue, :support_transcript,
                    :console_ticket_path, :console_tickets_path, :console_file_path
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
                     .includes(:requester, :assignee, :desk, :subject,
                               conversation: { last_message: %i[sender author] })
                     .limit(support_tickets_per_page)
      end

      # How many rows the index shows. Override, or paginate the relation
      # with whatever your app already uses.
      def support_tickets_per_page = 50
    end

    private

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

      flash[:alert] = support_console_t("errors.#{unavailable_reason}", holder: support_console_holder)
      respond_to_transition
    end

    # Why the button wasn't there, in the words that help most: the case is
    # done, somebody else has it, or nobody does and this desk wants it
    # taken first.
    def unavailable_reason
      return "closed_case" if @ticket.closed?
      return "unavailable_action" unless %i[reply hand_off].include?(action_name.to_sym)
      return "take_it_first" if @ticket.unassigned?

      "held_by_somebody_else"
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

      requested = params[:desk].presence&.to_sym
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
    def support_console_agent(id = params[:agent_id])
      return nil if id.blank?

      @ticket.desk.agents.detect { |agent| agent.id.to_s == id.to_s }
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
    def refuse(reason)
      flash[:alert] = support_console_t("errors.#{reason}")
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
      return true if RESCUED_ERRORS.any? { |klass| error.is_a?(klass) }
      return true if defined?(Chats::Error) && error.is_a?(Chats::Error)
      return true if defined?(ActiveRecord::RecordInvalid) && error.is_a?(ActiveRecord::RecordInvalid)

      false
    end

    # A translated sentence, never the exception's own text. The model
    # raises in English on purpose — those messages are written for whoever
    # is reading a stack trace — so passing one straight into a flash meant
    # a Spanish desk read "doesn't hold ticket T-AB12CD". `holder` carries
    # the one detail worth keeping, and the console knows it without having
    # to parse the error.
    def support_console_error_message(error)
      key = ERROR_KEYS[error.class.name] || "generic"
      support_console_t("errors.#{key}", detail: error.message, holder: support_console_holder)
    end

    def support_console_t(key, **interpolations)
      I18n.t("support_desk.console.#{key}", **interpolations)
    end
  end
end
