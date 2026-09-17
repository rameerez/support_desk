# frozen_string_literal: true

module SupportDesk
  # The `:support_console` routing concern — the one line that turns a few
  # RESTful actions into a working console:
  #
  #   namespace :madmin do
  #     resources :support_tickets, only: %i[index show new], concerns: :support_console
  #   end
  #
  # `new` stays yours — add it to `only:` when you render the form the
  # console's `open_conversation` posts to ("Write to someone"). The concern
  # draws the collection routes (`next`, `open_conversation`) and every
  # member verb.
  #
  # It draws the collection routes first and the member routes after, which
  # is what keeps `/madmin/support_tickets/next` from being swallowed by
  # `/madmin/support_tickets/:id` (a `resources` block draws its concerns
  # before its own member mappings, so "next" wins).
  #
  # == Why a Mapper patch
  #
  # Routing concerns live in `@concerns`, a Hash created fresh inside every
  # `Mapper`, i.e. once per `routes.draw` block. There is no registry a gem
  # can add to, so seeding the Hash at Mapper construction is the only way to
  # make `concerns: :support_console` read the way the PRD promises in the
  # HOST's routes file. The patch adds exactly one key and calls `super`
  # first; concerns the host defines themselves still win, because they are
  # assigned after this ran.
  module ConsoleRoutes
    # The name a host writes in their routes file.
    CONCERN = :support_console

    # The verbs, from the ONE table that has them: the concern that answers
    # them owns it, so a verb can never be routed without an action or
    # answered without a route. Kept here as an alias for a release, because
    # a host may have read it.
    MEMBER_VERBS = SupportDesk::Console::MEMBER_VERBS

    # Rails' own message for this ("can't use collection outside resource(s)
    # scope") is true and says nothing about which concern caused it, which
    # is a bad half-hour when the only support_desk line in the file is the
    # one word `concerns`.
    OUTSIDE_RESOURCE_SCOPE = <<~MESSAGE
      `concerns: :support_console` has to sit inside a `resources` block: it draws member routes
      (reply, take, assign, …) and a collection route (next) for a ticket resource, and neither
      means anything without one.

          namespace :madmin do
            resources :support_tickets, only: %i[index show], concerns: :support_console
          end

      or, if you prefer the block form:

          resources :support_tickets, only: %i[index show] do
            concerns :support_console
          end
    MESSAGE

    class << self
      # Make `concerns: :support_console` available in every route set.
      # Idempotent — the engine calls it at boot, tests may call it again.
      def install!
        return false if @installed

        require "action_dispatch"
        ActionDispatch::Routing::Mapper.prepend(MapperExtension)
        @installed = true
      end

      def installed? = !!@installed

      # Register the concern on one mapper. Also the escape hatch for a host
      # that would rather not have the patch at all:
      #
      #   Rails.application.routes.draw do
      #     SupportDesk::ConsoleRoutes.register(self)
      #     namespace(:madmin) { resources :support_tickets, concerns: :support_console }
      #   end
      def register(mapper)
        mapper.concern(CONCERN, Drawer.new)
        mapper
      end
    end

    # The concern itself, as the callable object Rails' `concern` documents —
    # so the routes are a plain object you can read, test and call.
    class Drawer
      # +options+ are whatever the host passed alongside the concern; they go
      # to every route, which is how `concerns :support_console, path: "t"`
      # keeps working.
      def call(mapper, options = {})
        # Read at DRAW time, from SupportDesk::Console — which is loaded by
        # the spine long before any routes file runs, so there is no
        # load-order risk in taking the verbs from the concern that answers
        # them rather than keeping a second list here.
        mapper.collection do
          SupportDesk::Console::COLLECTION_VERBS.each { |verb, method| mapper.public_send(method, verb, **options) }
        end

        mapper.member do
          SupportDesk::Console::MEMBER_VERBS.each { |verb| mapper.post verb, **options }
        end
      rescue ArgumentError => e
        raise unless e.message.include?("outside resource")

        raise SupportDesk::ConfigurationError, OUTSIDE_RESOURCE_SCOPE
      end
    end

    # Seeds the concern into every Mapper the moment one is built.
    module MapperExtension
      def initialize(...)
        super
        SupportDesk::ConsoleRoutes.register(self)
      end
    end
  end
end
