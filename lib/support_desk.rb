# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/object/blank"
require "global_id"

require "chats"

require_relative "support_desk/version"
require_relative "support_desk/errors"
require_relative "support_desk/events"
require_relative "support_desk/topic"
require_relative "support_desk/topic_tree"
require_relative "support_desk/configuration"
require_relative "support_desk/current"
require_relative "support_desk/macros"

require_relative "support_desk/engine" if defined?(::Rails::Engine)

# == SupportDesk
#
# Customer support for Rails apps: tickets that are conversations. A product
# gem on the `chats` kernel — chats owns the transcript, support_desk owns
# the case.
#
# The public surface is small on purpose:
#
#   SupportDesk.configure { |config| ... }   # one block, in an initializer
#   has_support_tickets                      # on whoever asks for help
#   supportable topic: :ride                 # on whatever they ask about
#   acts_as_support_agent if: :admin?        # on whoever answers
#
#   ticket = alice.ask_support!("No me han pagado", about: withdrawal)
#   ticket.assign!(to: lucia)
#   ticket.reply!("Lo estamos revisando", by: lucia)
#   ticket.close!(by: lucia)
#
# Everything else is queues, presenters and events — see the README.
module SupportDesk
  class << self
    include Events

    # --- Configuration --------------------------------------------------------

    def config
      @config ||= Configuration.new
    end

    alias configuration config

    # The one block a host writes, in an initializer. Validates what it
    # can right away; the checks that need the app's own classes run at
    # the first prepare.
    def configure
      yield config if block_given?
      config.validate!
      @configured = true
      config
    end

    # Whether a host has actually run `SupportDesk.configure`. Boot-time
    # class validation only bites once they have: a fresh `bundle add
    # support_desk` must still boot so you can run the install generator.
    def configured?
      !!@configured
    end

    # Reset the global state a test can dirty: configuration, subscribers,
    # and the memoised desks. Handy in a console too.
    #
    # The class registries are deliberately NOT cleared: they are a property
    # of the code that is loaded (the macros register at class definition
    # time), not of the configuration, and a host test suite shouldn't have
    # to re-declare its own models between examples.
    def reset!
      @config = Configuration.new
      @configured = false
      @subscribers = nil
      @desks = nil
      self
    end

    # Forget the memoised Desk records without touching configuration — for
    # tests that truncate tables between examples.
    def reset_desks!
      @desks = nil
      self
    end

    # --- Desks ------------------------------------------------------------------

    # The desk record for +key+, memoised per process.
    #
    # Lazily created with `find_by || create_or_find_by!` and NEVER
    # INSERT-first: a desk is read thousands of times and written once, and
    # an INSERT that fails its unique index on every page view is noise in
    # the log and a wasted round trip.
    def desk(key = :default)
      key = (key || :default).to_sym
      return nil unless config.desk?(key) || key == :default

      desks[key] ||= Desk.for(key)
    end

    # Every desk record this process has resolved, keyed by key.
    def desks # :nodoc:
      @desks ||= {}
    end

    # --- Topics -----------------------------------------------------------------

    # The Topic at +path+, looked up across every configured desk's tree, or
    # a Topic::Unknown that still renders (never raises in a view).
    def find_topic(path)
      return nil if path.nil?

      path = path.to_s
      config.desks.each_value do |desk|
        node = desk.topics.find(path)
        return node if node
      end

      Topic::Unknown.new(path)
    end

    # --- Registries ---------------------------------------------------------------
    #
    # The macros self-register the calling class here. We store class NAMES
    # (strings), not Class objects, so the registry survives Zeitwerk code
    # reloading in development (a reloaded class is a brand new object; its
    # name is stable).

    # Called by the macros. Returns the class, so it composes.
    def register_requester(klass) = register(requester_class_names, klass)
    def register_supportable(klass) = register(supportable_class_names, klass)
    # Called by `acts_as_support_agent`. Returns the class.
    def register_agent(klass) = register(agent_class_names, klass)

    # The registered class names, as Sets of Strings.
    def requester_class_names = @requester_class_names ||= Set.new
    def supportable_class_names = @supportable_class_names ||= Set.new
    # Every class that has declared itself able to answer.
    def agent_class_names = @agent_class_names ||= Set.new

    # Whether +klass+ (a Class, an instance, or a class name) is supportable.
    def supportable_class?(klass) = registered?(supportable_class_names, klass)
    # Whether +klass+ asks for support / answers it. Ancestor-aware, so an
    # STI subclass of a registered class counts.
    def requester_class?(klass) = registered?(requester_class_names, klass)
    def agent_class?(klass) = registered?(agent_class_names, klass)

    # --- The chats seam -------------------------------------------------------------

    # Subscribe the gem's own `:message_created` listener, which is what
    # keeps `awaiting`, the SLA clocks and reopen-on-reply true without
    # anybody remembering to call anything.
    #
    # Safe to call as often as you like: chats replaces a subscriber
    # registered under the same `key:` rather than stacking another one.
    # There is deliberately NO "already subscribed" flag here — one would
    # make re-subscribing after a `Chats.reset!` a silent no-op, and the
    # first sign of that is a desk whose tickets stop knowing whose turn it
    # is, with nothing in the log.
    def subscribe_to_chats!
      Chats.on(:message_created, key: :support_desk) do |message|
        # The constant is resolved on every call on purpose: in development
        # the Ticket class is a new object after each reload.
        SupportDesk::Ticket.for_conversation(message.conversation)&.register!(message)
      end
      self
    end

    # --- Health -------------------------------------------------------------------

    # Everything that can only be checked against a running app:
    # configuration, the chats seams, and the data invariants.
    # `SupportDesk.doctor.ok?` is the one line to put in CI.
    def doctor = Doctor.run

    # --- Internals ----------------------------------------------------------------

    def logger
      defined?(::Rails) ? ::Rails.logger : nil
    end

    # Where the host mounted the requester-facing engine
    # ("/messages/support"), or nil when they haven't. Used for the grouped
    # inbox row's link and by `doctor`.
    #
    # Read from the route set rather than from a URL helper on purpose: the
    # answer has to exist before the engine has drawn a single route.
    def root_path
      return nil unless defined?(::Rails) && ::Rails.application

      route = ::Rails.application.routes.routes.find do |candidate|
        candidate.app.respond_to?(:app) && candidate.app.app == SupportDesk::Engine
      end
      return nil unless route

      path = route.path.spec.to_s.sub("(.:format)", "")
      path.empty? ? "/" : path
    rescue StandardError
      nil
    end

    # A stable, URL-safe key for an actor (agent, requester, desk), used in
    # cache keys and event payloads. GlobalID params already encode class +
    # id, so two classes can never collide.
    def actor_key(record)
      return nil if record.nil?
      return record.to_s if record.is_a?(Symbol)

      record.to_global_id.to_param
    end

    private

    def register(registry, klass)
      registry << klass.name if klass.name
      klass
    end

    def registered?(registry, klass)
      klass = klass.class unless klass.is_a?(Class) || klass.is_a?(String)
      name = klass.is_a?(String) ? klass : klass.name
      return true if registry.include?(name)

      constant = klass.is_a?(String) ? name.safe_constantize : klass
      return false unless constant.respond_to?(:ancestors)

      constant.ancestors.any? { |ancestor| registry.include?(ancestor.name) }
    end
  end
end
