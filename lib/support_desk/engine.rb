# frozen_string_literal: true

require "rails/engine"

module SupportDesk
  # The mountable engine: wires autoloading, migrations, locales, the
  # ActiveRecord macros, and boot-time configuration into the host app.
  #
  #   mount SupportDesk::Engine => "/support"
  #
  # The requester-facing screens live here; the agent console is BYOUI
  # (query objects, presenters and a generator — see the README).
  class Engine < ::Rails::Engine
    isolate_namespace SupportDesk

    # -------------------------------------------------------------------------
    # Zeitwerk: the gem keeps its ActiveRecord models under
    # lib/support_desk/models (the same layout as chats and moderate) so the
    # whole domain ships in lib/ and the engine's app/ tree only holds the
    # web layer. For that to autoload we manage the loader by hand:
    #
    #   - push_dir(lib/support_desk, namespace: SupportDesk) makes
    #     lib/support_desk/models/... autoloadable under the SupportDesk
    #     namespace.
    #   - collapse(models) + collapse(models/concerns) mean those files
    #     define SupportDesk::Ticket, not SupportDesk::Models::Ticket.
    #   - The SPINE files are required explicitly by lib/support_desk.rb at
    #     boot (the configuration DSL has to exist before any initializer
    #     runs), so they must be IGNORED by the loader or Zeitwerk would
    #     complain about unmanaged constants.
    # -------------------------------------------------------------------------
    LIB_ROOT = File.expand_path("..", __dir__)
    SUPPORT_DESK_LIB = File.expand_path("support_desk", LIB_ROOT)

    ZEITWERK_IGNORED = %w[
      version.rb errors.rb events.rb topic.rb topic_tree.rb configuration.rb current.rb macros.rb engine.rb
    ].freeze

    initializer "support_desk.autoload", before: :set_autoload_paths do
      loader = Rails.autoloaders.main

      ZEITWERK_IGNORED.each do |file|
        path = File.join(SUPPORT_DESK_LIB, file)
        loader.ignore(path) if File.exist?(path)
      end

      %w[models models/concerns].each do |dir|
        path = File.join(SUPPORT_DESK_LIB, dir)
        loader.collapse(path) if File.directory?(path)
      end

      loader.push_dir(SUPPORT_DESK_LIB, namespace: SupportDesk)
    end

    config.eager_load_paths << SUPPORT_DESK_LIB

    # Make the gem's migrations runnable from the host without copying. The
    # install generator still copies a host-owned migration, which is the
    # recommended path; this mainly serves the dummy app.
    initializer "support_desk.migrations" do |app|
      unless app.root.to_s == root.to_s
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path
        end
      end
    end

    # Expose `has_support_tickets` / `supportable` / `acts_as_support_agent`
    # on every AR model.
    initializer "support_desk.active_record" do
      ActiveSupport.on_load(:active_record) do
        extend SupportDesk::Macros
      end
    end

    # Serve the bundled stylesheet the requester-facing views link (propshaft
    # or sprockets — both honour config.assets.paths). A host that ejects and
    # restyles the views simply stops rendering `support_desk_styles`.
    initializer "support_desk.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/assets/stylesheets")
      end
    end

    # Ship the gem's locale files (en, es). Host locale files with the same
    # keys override these automatically (I18n's load order puts the app last).
    initializer "support_desk.locales" do |app|
      app.config.i18n.load_path += Dir[root.join("config", "locales", "**", "*.{rb,yml}").to_s]
    end

    # Keep `awaiting`, the SLA clocks and reopen-on-reply true by listening
    # to chats. One subscriber, registered once, for every channel a message
    # can arrive through.
    initializer "support_desk.chats_subscribers" do
      SupportDesk.subscribe_to_chats!
    end

    # The checks that need the host's own classes loaded — the requester
    # class, and every `about:` class named in a topic tree. In to_prepare
    # (not an initializer) so they re-run after every code reload, which is
    # exactly when a model stops being `supportable`.
    config.to_prepare do
      SupportDesk.config.validate_classes! if SupportDesk.configured?
    end
  end
end
