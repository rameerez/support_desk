# frozen_string_literal: true

require "rails/engine"

module SupportDesk
  # The turnkey console, for hosts with no admin framework to hang one off:
  #
  #   mount SupportDesk::ConsoleEngine => "/admin/support"
  #
  # It is Layer 2 with the views filled in — the same controller concern any
  # host would include, and the same templates `rails g support_desk:console`
  # writes into an app. One source of truth: the generator copies these
  # files, so what you see mounted is what you get when you eject.
  #
  # Authentication and layout come from `config.console_parent_controller`,
  # the way the requester engine takes `config.parent_controller`. Mounting
  # this engine grants nothing: `require_support_agent!` still runs, and so
  # does `config.authorize_console`.
  #
  # == Why it isolates SupportDesk::Console
  #
  # Two engines can't isolate the same namespace — the second would steal
  # `SupportDesk.railtie_namespace` from the first, and the requester
  # engine's URL helpers with it. So the console's controllers live under
  # `SupportDesk::Console`, which is also the concern hosts include: one name
  # for the console, whichever layer you use it from.
  class ConsoleEngine < ::Rails::Engine
    isolate_namespace SupportDesk::Console

    # Its own routes file: the requester engine already owns
    # `config/routes.rb`, and an engine that doesn't say otherwise would draw
    # that same file a second time.
    paths["config/routes.rb"] = "config/console_routes.rb"

    # `concerns: :support_console` in the HOST's routes file. Registered from
    # an initializer, which is early enough: the app's routes are not drawn
    # until every railtie initializer has run.
    #
    # This lives on the console engine rather than the requester one because
    # defining the class is what loads it — a host that never mounts this
    # engine still gets the concern.
    initializer "support_desk.console.routing_concern" do
      SupportDesk::ConsoleRoutes.install!
    end
  end
end
