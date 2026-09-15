# frozen_string_literal: true

module SupportDesk
  # Base controller for every requester-facing screen. It inherits from the
  # HOST's controller (`config.parent_controller`, "::ApplicationController"
  # by default) so the host's layout, helpers, authentication, locale
  # switching and exception handling all apply to the support screens for
  # free — the same integration style as chats.
  #
  # NOTE: the superclass is resolved when this class is autoloaded, which in
  # a booted app happens AFTER initializers — so `config.parent_controller`
  # set in config/initializers/support_desk.rb is honoured. In development
  # the class is reloaded on every change, picking up config changes too.
  class ApplicationController < SupportDesk.config.parent_controller.constantize
    before_action :support_desk_authenticate!
    before_action :ensure_requester!
    before_action :set_support_desk_current

    helper SupportDesk::EngineHelper
    helper_method :current_requester

    private

    # The person asking for help, via the host-configured method
    # (`current_user` by default — Devise-compatible out of the box).
    def current_requester
      return @current_requester if defined?(@current_requester)

      method_name = SupportDesk.config.current_requester_method
      unless respond_to?(method_name, true)
        raise SupportDesk::ConfigurationError,
              "support_desk can't find ##{method_name} on #{self.class.superclass.name}. " \
              "Set config.current_requester_method in config/initializers/support_desk.rb " \
              "to the controller method that returns the logged-in #{SupportDesk.config.requester_class}."
      end

      @current_requester = send(method_name)
    end

    # The host's own authentication filter, so a logged-out visitor meets the
    # host's login flow and never this gem's idea of one.
    def support_desk_authenticate!
      method_name = SupportDesk.config.authenticate_method
      unless respond_to?(method_name, true)
        raise SupportDesk::ConfigurationError,
              "support_desk can't find ##{method_name} on #{self.class.superclass.name}. " \
              "Set config.authenticate_method in config/initializers/support_desk.rb " \
              "to your authentication filter (e.g. :authenticate_user! with Devise)."
      end

      send(method_name)
    end

    # A host whose authentication filter lets anonymous requests through gets
    # a 401 rather than a NoMethodError three frames deeper; a host whose
    # current_requester_method returns the wrong model gets the fix in the
    # message, because that is a configuration mistake, not a request one.
    def ensure_requester!
      return head :unauthorized if current_requester.nil?
      return if current_requester.respond_to?(:ask_support!)

      raise SupportDesk::ConfigurationError,
            "config.current_requester_method (##{SupportDesk.config.current_requester_method}) returned a " \
            "#{current_requester.class}, which doesn't declare `has_support_tickets`. " \
            "Point it at your #{SupportDesk.config.requester_class}, or add the macro to #{current_requester.class}."
    end

    # Every transition takes `by:`; this is what it falls back to, so a
    # requester's own actions are attributed to them without the views
    # passing an actor around.
    def set_support_desk_current
      SupportDesk::Current.actor = current_requester
      SupportDesk::Current.request = request
    end

    # Engine URL helpers for chats, from a controller. The mounted proxy
    # carries the host's mount prefix ("/messages"); the engine's own
    # url_helpers are the prefix-less fallback for a host that hasn't
    # mounted chats under its default name.
    def chats_routes
      respond_to?(:chats) ? chats : Chats::Engine.routes.url_helpers
    end

    # Where a case is read and answered: its chats conversation, never a
    # second thread UI of our own.
    def conversation_path_for(ticket)
      return root_path if ticket.conversation.nil?

      chats_routes.conversation_path(ticket.conversation)
    end
  end
end
