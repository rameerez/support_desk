# frozen_string_literal: true

module SupportDesk
  module Console
    # Base controller for the turnkey console. It inherits from the HOST's
    # controller (`config.console_parent_controller`, "::ApplicationController"
    # by default), so the host's layout, helpers, authentication filters,
    # locale switching and exception handling all apply to the console
    # screens — the same integration style as the requester engine.
    #
    # NOTE: the superclass is resolved when this class is autoloaded, which in
    # a booted app happens AFTER initializers — so a
    # `config.console_parent_controller` set in config/initializers is
    # honoured. In development the class reloads with the rest of the app.
    class ApplicationController < SupportDesk.config.console_parent_controller.constantize
    end
  end
end
