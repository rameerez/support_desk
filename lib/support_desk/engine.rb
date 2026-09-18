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
      console.rb console_routes.rb console_engine.rb
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
        # Sprockets compiles only what is declared; without this the host
        # 404s the stylesheet in production while Propshaft (which serves
        # everything on the path) works fine, so the gap only shows up on
        # somebody else's deploy.
        app.config.assets.precompile << "support_desk.css" if app.config.assets.respond_to?(:precompile)
      end
    end

    # The gem's locale files (en, es) ship through Rails::Engine's own
    # :add_locales initializer, which picks up every engine's config/locales
    # automatically — and deliberately NOT through a manual
    # `app.config.i18n.load_path +=` on top of it.
    #
    # That manual append is not merely redundant, it INVERTS the contract.
    # Railtie paths are unshifted ahead of everything in load_path, so an
    # appended copy of these files lands AFTER the host's own locales and
    # silently overrides them: a host that rewords `support_desk.queue.tabs
    # .awaiting` in its own es.yml would keep reading ours. Measured before
    # this was removed: the gem's file sat in load_path 14 times and the
    # host's override lost.
    #
    # Gem first, host last. `clickwrap` learned this the same way and its
    # engine carries the same note.

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
      # Touch the helper so its bottom-of-file on_load(:action_view) hook
      # registers even when no engine code has been referenced yet. Without
      # this, `link_to_support` is undefined in every host that does not
      # eager load — which is every host in development.
      # (Assigned to appease Lint/Void — the constant REFERENCE is the point.)
      _loaded = SupportDesk::EngineHelper

      # Touch the desk for the same reason, on the CHATS side. `acts_as_messager`
      # registers a class with chats when that class LOADS, and `Chats::Inbox`
      # reads that registry (`Chats.grouped_messager_types`) to decide which
      # messager types fold into one inbox row. Under lazy autoloading nothing
      # has referenced SupportDesk::Desk by the time a requester opens their
      # inbox, so the registry is empty, the stacking prefilter matches nothing,
      # and every support conversation renders as its own row — the exact noise
      # the grouped row exists to prevent. Eager-loading hosts (production)
      # never see it; development does, and "works in prod, wrong locally" is
      # the worst shape for a bug. Found by the CarHey integration (#2).
      _desk = SupportDesk::Desk

      # And the assistant, for the THIRD registry with the same shape:
      # `acts_as_support_agent` registers a class when that class loads, and
      # both `SupportDesk.agent_class?` and the doctor's "ai agents without
      # policy" check read that registry. Under lazy autoloading nothing has
      # referenced her before the first case is answered, so the doctor would
      # report a healthy desk as having no assistant at all. A constant
      # reference and nothing else: no row is created and no connection is
      # needed to load the class.
      _assistant = SupportDesk::Assistant

      SupportDesk.config.validate_classes! if SupportDesk.configured?
    end
  end
end
