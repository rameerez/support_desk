# frozen_string_literal: true

module SupportDesk
  module Console
    # The whole turnkey console, and proof the public API is enough: the
    # queue, one case, and the verbs — all of it from the same two concerns
    # a host includes in their own controller, with nothing private.
    #
    # `rails g support_desk:console madmin` writes a controller that reads
    # exactly like this one into the host app, and copies these views next to
    # it. If you find yourself wanting something this controller can't do,
    # that is a gap in Layer 1 or Layer 2 — not a reason to reach in here.
    class TicketsController < ApplicationController
      include SupportDesk::Console
      include SupportDesk::Console::Index

      # One case: the context card, the transcript, the timeline, and exactly
      # the buttons `actions_for` says this agent may press. `@ticket` is set
      # by the concern, scoped to the desks this agent may work.
      def show
        @context_card = @ticket.context_card
        @actions = @ticket.actions_for(current_agent)
      end
    end
  end
end
