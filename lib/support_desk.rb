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
require_relative "support_desk/assistant_policy"
require_relative "support_desk/topic"
require_relative "support_desk/topic_tree"
require_relative "support_desk/configuration"
require_relative "support_desk/current"
require_relative "support_desk/macros"
# The console's Layer 2. Spine rather than autoloaded, because the engine
# isolates SupportDesk::Console as its namespace and a namespace has to
# exist before an engine can isolate it.
require_relative "support_desk/console"
require_relative "support_desk/console_routes"

if defined?(::Rails::Engine)
  require_relative "support_desk/engine"
  require_relative "support_desk/console_engine"
end

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
  # Assertions and builders for host test suites. Autoloaded, the way
  # organizations and clickwrap expose theirs, so a host writes
  # `include SupportDesk::TestHelpers` without a require and a production
  # boot never loads the file.
  autoload :TestHelpers, "support_desk/test_helpers"

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
      @assistants = nil
      self
    end

    # Forget the memoised Desk records without touching configuration — for
    # tests that truncate tables between examples.
    def reset_desks!
      @desks = nil
      self
    end

    # --- Assistants -----------------------------------------------------------

    # The assistant record for +key+, memoised per process — or the desk's
    # default when called with nothing. nil when this installation has no
    # assistant at all, which is the answer every existing host gets.
    #
    # Found or created exactly like a desk, and never INSERT-first: an
    # assistant is read on every transition and written once in her life.
    def assistant(key = nil)
      key = (key || config.default_assistant_key)
      return nil if key.nil?

      key = key.to_sym
      unless config.assistant?(key)
        raise ConfigurationError,
              "no assistant #{key.inspect} is configured — declare it with " \
              "`config.assistant #{key.inspect} do |assistant| … end`"
      end

      # Resolving her is also when what she is CALLED is written down, so a
      # message she signed still says the same thing after somebody takes
      # her out of the initializer (R8). It writes only when configuration
      # and the row disagree.
      (assistants[key] ||= Assistant.for(key)).snapshot_disclosure!
    end

    # Every assistant record this process has resolved, keyed by key.
    def assistants # :nodoc:
      @assistants ||= {}
    end

    # Forget the memoised Assistant records without touching configuration —
    # for tests that truncate tables between examples.
    def reset_assistants!
      @assistants = nil
      self
    end

    # Whether +record+ is a machine rather than a person. Duck-typed, because
    # a host's own `acts_as_support_agent kind: :ai` model answers it too —
    # and is then refused everywhere, which is the point (I2).
    def ai_actor?(record)
      record.respond_to?(:support_agent_kind) && record.support_agent_kind == :ai
    end

    # Give back every seat an assistant can no longer sit in — she was
    # switched off, her configuration was removed, or her policy no longer
    # lets her hold a case — and ask for a person on each of them.
    #
    # Invalid-assignee recovery, NOT silence detection: it reads the seats
    # that exist rather than the assistants a running process happens to
    # have configured, so a `deactivate!`, a flag flipped off and a topic
    # cap tightened are all covered, with no `responds_within` and no
    # overdue clock anywhere in it (R6). `release_silent_assistants!` runs
    # it first; `rake support_desk:reclaim_assistant_seats` runs it alone.
    #
    # Returns how many seats it reclaimed.
    def reclaim_assistant_seats!
      return 0 unless Assistant.table_exists?

      reclaimed = 0
      Ticket.open.held_by_assistants.find_each do |ticket|
        reclaimed += 1 if ticket.reclaim_assistant_seat!
      rescue StandardError => e
        report_error(e, context: { hook: :reclaim_assistant_seats, ticket: ticket.id })
      end
      logger&.info("[support_desk] reclaimed #{reclaimed} stranded assistant seat(s)") if reclaimed.positive?
      reclaimed
    end

    # Release every assistant who has sat on a case longer than her
    # `responds_within` without answering — and ask for a person on it.
    #
    # This is the net under a dead harness: a queue worker that stopped, a
    # model provider that is down, a job that raised its last retry away.
    # Run it every minute (`rake support_desk:release_silent_assistants`).
    # Returns how many cases it moved.
    def release_silent_assistants!
      # A seat nobody can sit in any more is not a silence problem, and it
      # must not need a `responds_within` to be noticed (R6).
      moved = reclaim_assistant_seats!
      config.assistants.each_key do |key|
        agent = assistant(key)
        window = agent&.responds_within
        next if window.nil?

        Ticket.open.assigned_to(agent).awaiting_reply.waiting_over(window).find_each do |ticket|
          # Conditional, under the case's own lock: every predicate above was
          # true when this row was SELECTED, and a person may have answered
          # it since (R5).
          moved += 1 if ticket.escalate_if_still_silent!(agent, window)
        rescue StandardError => e
          report_error(e, context: { hook: :release_silent_assistants, ticket: ticket.id })
        end
      end
      logger&.info("[support_desk] silent assistants: #{moved} case(s) handed to a person") if moved.positive?
      moved
    end

    # Re-emit `:assistant_turn` for cases whose turn nobody acted on — a
    # harness that was down when the event fired, a job that was dropped.
    #
    # At-least-once on purpose: a duplicate turn is harmless, because the
    # turn is consumed by the first action and every later one is a
    # StaleTurn. Run it every five minutes. Returns how many it re-emitted.
    def redispatch_assistant_turns!(older_than: 1.minute)
      older_than = older_than.to_i.seconds unless older_than.respond_to?(:ago)
      emitted = 0

      config.desks.each_key do |key|
        agent = desk(key)&.assistant
        # Repair before deciding. A requester message whose registration was
        # lost after commit leaves the clocks describing a case that no longer
        # exists — and `assistant_idle_since` reads those clocks, so the case
        # it most needs to find is the one it cannot see. Folding the message
        # in COMMITS on its own and emits the turn it produces, so a dead
        # process followed by nothing but this task still ends in an
        # actionable turn (R3).
        Ticket.for_desk(key).with_unregistered_requester_messages.find_each do |ticket|
          emitted += 1 if ticket.reconcile_and_commit!.positive?
        rescue StandardError => e
          report_error(e, context: { hook: :redispatch_assistant_turns, ticket: ticket.id })
        end

        next if agent.nil?

        Ticket.open.for_desk(key).assistant_idle_since(older_than.ago).find_each do |ticket|
          next unless ticket.assistant_policy(agent).may_observe?

          ticket.send(:emit_assistant_turn)
          emitted += 1
        end
      end
      emitted
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

    # The registered classes themselves, for the places that have to restrict
    # a lookup to them — the console's GlobalID allow-lists, where a raw
    # token is an identifier and never an authorization to call `find` on
    # whatever class name it names.
    #
    # Names that no longer resolve are dropped rather than raised on: the
    # registries store names so they survive reloads, and a class that went
    # away is simply not one of the classes people can be looked up as.
    def requester_classes = resolve_all(requester_class_names)
    def supportable_classes = resolve_all(supportable_class_names)

    # Whether +klass+ (a Class, an instance, or a class name) is supportable.
    def supportable_class?(klass) = registered?(supportable_class_names, klass)
    # Whether +klass+ asks for support / answers it. Ancestor-aware, so an
    # STI subclass of a registered class counts.
    def requester_class?(klass) = registered?(requester_class_names, klass)
    def agent_class?(klass) = registered?(agent_class_names, klass)

    # --- Macro conditions -----------------------------------------------------------

    # Whether +record+ passes an `if:` condition from a macro — nil is always
    # yes. Both `has_support_tickets if:` (may this person ask for help, and
    # be written to) and `acts_as_support_agent if:` (may this person answer)
    # are read through here, so the two conditions can never drift into two
    # meanings of the same option.
    def eligible?(record, condition)
      return true if condition.nil?
      return !!record.public_send(condition) if condition.is_a?(Symbol)

      !!condition.call(record)
    end

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

    # Report an exception the way the event dispatcher does: `Rails.error`
    # when there is one, the log otherwise. Extracted because every hook the
    # gem runs on a host's behalf — a `hand_off_when` block, a turn
    # emission, a sweep — has to report and carry on rather than take a
    # transition down with it.
    def report_error(error, context: {}) # :nodoc:
      if defined?(Rails) && Rails.respond_to?(:error) && Rails.error
        Rails.error.report(error, handled: true, source: "support_desk", context: context)
      else
        logger&.error("[support_desk] #{error.class}: #{error.message} #{context.inspect}")
      end
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

    # The Hotwire Native path-configuration rules for the requester-facing
    # engine, ready to splat into a host's own `rules` array:
    #
    #   rules: [ *SupportDesk.native_path_rules, *my_own_rules ]
    #
    # Both surfaces are ordinary PUSHED screens (`context: "default"`), never
    # modals: the wizard is three real URLs and a modal would break the back
    # gesture between them. The thread itself is deliberately absent — it is
    # a chats conversation, and it stays under the host's chats rule.
    #
    # +mount+ defaults to wherever the engine is mounted and +title+ to the
    # desk's name.
    def native_path_rules(mount: nil, title: nil)
      mount = (mount || root_path)&.to_s&.chomp("/")
      if mount.blank?
        raise ConfigurationError,
              "SupportDesk.native_path_rules can't tell where the engine is mounted. " \
              "Mount it (`mount SupportDesk::Engine => \"/support\"`) or pass mount: \"/support\"."
      end

      title ||= config.name
      prefix = Regexp.escape(mount)

      [
        {
          patterns: [ "^#{prefix}/?(?:\\?.*)?$" ],
          properties: { context: "default", title: title, pull_to_refresh_enabled: true },
          comment: "The requester's support list: a pushed screen, pull to refresh like any other list."
        },
        {
          patterns: [ "^#{prefix}/new(?:\\?.*)?$" ],
          properties: { context: "default", title: title, pull_to_refresh_enabled: false },
          comment: "The wizard: every step is a real URL, so it pushes and the back gesture works. " \
                   "Pull to refresh is off — it would throw away what the requester has typed."
        }
      ]
    end

    # A duration in the reader's own language ("1 día", "4 hours") — the
    # answer promise in the wizard's line, the wait in a console summary, and
    # the `%{reply_within}` an opening line can interpolate.
    #
    # Duration#inspect is English whatever the locale, which is what left one
    # untranslatable string in an otherwise Spanish console.
    def humanize_duration(duration)
      return duration.inspect unless defined?(ActionView::Helpers::DateHelper)

      @duration_words ||= Object.new.extend(ActionView::Helpers::DateHelper)
      words = @duration_words.distance_of_time_in_words(duration.to_i).to_s
      # An app whose locale has no date translations (no rails-i18n) would
      # otherwise show "Translation missing" to a customer.
      words.start_with?("Translation missing") ? duration.inspect : words
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

    def resolve_all(registry)
      registry.filter_map { |name| name.safe_constantize }
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
