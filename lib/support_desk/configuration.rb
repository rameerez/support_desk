# frozen_string_literal: true

require "active_support/core_ext/module/delegation"
require_relative "topic_tree"

module SupportDesk
  # Everything a desk decides, with defaults that already work.
  #
  #   SupportDesk.configure do |config|
  #     config.name = "Soporte CarHey"
  #     config.agents { User.admin }
  #     config.topics do
  #       topic :ride, about: Ride
  #       other
  #     end
  #   end
  #
  # Two rules shared with the rest of the gem ecosystem:
  #
  # 1. Class names are stored as STRINGS and constantized lazily, so the
  #    initializer can name app classes before they load and everything
  #    survives Zeitwerk reloads.
  # 2. Setters validate ON ASSIGNMENT and raise SupportDesk::ConfigurationError
  #    with the fix in the message — a configuration mistake is a boot
  #    failure, never a 3am NoMethodError.
  #
  # == Desks
  #
  # Most apps have one desk and never think about it: the top-level setters
  # configure the `:default` desk. Apps with more say so explicitly, and any
  # setting a desk doesn't state falls back to the default desk's:
  #
  #   config.desk :billing do |desk|
  #     desk.name = "Facturación"
  #     desk.reply_within = 8.hours
  #   end
  class Configuration
    # Everything a single desk decides. A desk reads its own value when it
    # has one and the default desk's otherwise, so `config.reply_within =
    # 24.hours` at the top level really does mean "every desk, unless it
    # says otherwise".
    class DeskConfiguration
      REPLY_POLICIES = %i[anyone take_over assignee_only].freeze
      ANNOUNCE_MODES = %i[always first_only never].freeze
      CLOSED_TICKET_MODES = %i[reopen_on_reply locked].freeze
      INBOX_ENTRY_MODES = %i[always when_tickets never].freeze
      MIRROR_MODES = %i[always when_away never].freeze
      ROUTING_STRATEGIES = %i[manual round_robin least_loaded].freeze
      # Strategies that need the 0.3 duty/capacity tables; naming one now
      # fails at boot instead of silently leaving tickets unassigned.
      UNRELEASED_ROUTING_STRATEGIES = %i[round_robin least_loaded].freeze

      # The sample a static opening line is interpolated against the moment it
      # is assigned, so a typo'd %{labe} is a boot failure and not a 3am
      # exception in the middle of somebody opening a case.
      LINE_INTERPOLATIONS = { label: "…", desk: "…", reply_within: "…" }.freeze

      DEFAULTS = {
        name: nil,
        avatar: nil,
        email: nil,
        opening_line: nil,
        # A message from a desk you never wrote to has to explain itself, so
        # this one has a default and `opening_line` does not: existing hosts'
        # threads keep opening exactly as they do today.
        opening_line_from_support: :"support_desk.thread.opened_by_support",
        find_requester: nil,
        reply_policy: :anyone,
        announce_assignments: :first_only,
        closed_tickets: :reopen_on_reply,
        reply_within: 24 * 60 * 60,
        at_risk_after: 4 * 60 * 60,
        open_rate_limit: { to: 5, within: 60 * 60 },
        max_open_tickets: 5,
        inbox_entry: :always,
        routing: :manual,
        mirror_replies_by_email: :when_away,
        auto_close_after: nil
      }.freeze

      attr_reader :key, :fallback

      # A desk's settings, falling back to +fallback+ for anything it
      # doesn't state (the default desk, for every desk but itself).
      def initialize(key, fallback: nil)
        @key = key.to_sym
        @fallback = fallback
        @settings = {}
        @topics_block = nil
        @topics = nil
      end

      # --- The desk's identity --------------------------------------------------

      # What requesters see as the counterpart in their inbox.
      def name = read(:name) || key.to_s.humanize

      # nil un-sets the name, so the desk goes back to inheriting it (or to
      # its humanized key). A blank string is a mistake, not an intention.
      def name=(value)
        return @settings.delete(:name) if value.nil?

        @settings[:name] = ensure_present_string(value, "name")
      end

      # An asset path, a URL, or ->(desk) { … }. Anything `image_tag` accepts.
      def avatar = read(:avatar)

      # Set it, validating on assignment (see the reader above).
      def avatar=(value)
        unless value.nil? || value.is_a?(String) || value.respond_to?(:call)
          raise ConfigurationError, "avatar must be a String, a callable, or nil, got #{value.inspect}"
        end

        @settings[:avatar] = value
      end

      # The address the email channel answers from (0.2).
      def email = read(:email)

      # Set it, validating on assignment (see the reader above).
      def email=(value)
        if value && !value.to_s.include?("@")
          raise ConfigurationError, "email must be an email address, got #{value.inspect}"
        end

        @settings[:email] = value&.to_s
      end

      # --- What a thread opens with ---------------------------------------------

      # The system line every thread opens with, posted INSIDE the opening
      # transaction and before the first message, so it can never arrive
      # after the message it introduces (or not at all).
      #
      # A String with %{label}, %{desk} and %{reply_within}; a Symbol naming
      # an I18n key that takes the same interpolations; a block given the
      # ticket; or nil for no line at all, which is the default.
      #
      #   config.opening_line = "Has abierto una conversación sobre «%{label}»."
      #   config.opening_line { |ticket| ticket.subject ? … : … }
      def opening_line(&block)
        return @settings[:opening_line] = block if block

        read(:opening_line)
      end

      # Set it, validating on assignment (see the reader above).
      def opening_line=(value)
        @settings[:opening_line] = ensure_line(value, "opening_line")
      end

      # The same line for a case the DESK opened. Defaults to the gem's own
      # I18n key, because somebody who never wrote to you needs to be told
      # what this is.
      def opening_line_from_support(&block)
        return @settings[:opening_line_from_support] = block if block

        read(:opening_line_from_support)
      end

      # Set it, validating on assignment (see the reader above).
      def opening_line_from_support=(value)
        @settings[:opening_line_from_support] = ensure_line(value, "opening_line_from_support")
      end

      # How a console finds the person an agent types: email, phone, handle,
      # whatever this host lets staff search by. Given the typed string,
      # returns a requester record or nil.
      #
      #   config.find_requester { |query| User.find_by(email: query.to_s.strip.downcase) }
      #
      # nil (the default) means the console accepts only a GlobalID from one
      # of your own pages. Multi-tenant hosts scope BOTH ways in — this hook
      # is a lookup, never an authorization.
      def find_requester(&block)
        return @settings[:find_requester] = block if block

        read(:find_requester)
      end

      # Set it, validating on assignment (see the reader above).
      def find_requester=(value)
        @settings[:find_requester] = value.nil? ? nil : ensure_callable(value, "find_requester")
      end

      # What's wrong with this desk's opening lines, as sentences — what
      # `doctor` reports. A String is interpolated against the sample, a
      # Symbol has to exist in the current locale, and a block is left alone:
      # it needs a ticket, and running a host's callback as a diagnostic is
      # not a diagnostic.
      def opening_line_problems # :nodoc:
        %i[opening_line opening_line_from_support].filter_map do |setting|
          value = public_send(setting)
          next if value.nil? || value.respond_to?(:call)

          if value.is_a?(Symbol)
            next if I18n.exists?(value)

            "#{setting} names #{value.inspect}, which has no #{I18n.locale} translation"
          else
            begin
              interpolate_line(value, LINE_INTERPOLATIONS, setting.to_s)
              nil
            rescue ConfigurationError => e
              e.message
            end
          end
        end
      end

      # What to post for THIS ticket, resolved and interpolated in the
      # current locale. nil or blank means post nothing.
      def opening_line_for(ticket)
        setting = ticket.opened_by_support? ? opening_line_from_support : opening_line
        return nil if setting.nil?

        line = case setting
        when Symbol then I18n.t(setting, **line_interpolations(ticket), raise: true)
        when String then interpolate_line(setting, line_interpolations(ticket), "opening_line")
        else setting.call(ticket)
        end
        return nil if line.nil?

        unless line.is_a?(String)
          raise ConfigurationError,
                "an opening_line block must return a String or nil, got #{line.inspect}"
        end

        line
      end

      # --- Who answers ----------------------------------------------------------

      # The agent pool: notified while a ticket is unassigned, offered in the
      # "assign to" picker, and what routing chooses from.
      #
      #   config.agents { User.admin }
      #   config.agents = -> { User.where(support: true) }
      def agents(&block)
        return @settings[:agents] = block if block

        read(:agents)
      end

      # Set it, validating on assignment (see the reader above).
      def agents=(value)
        @settings[:agents] = ensure_callable(value, "agents")
      end

      # The pool, resolved. Raises ConfigurationError when the host's block
      # hands back something that isn't a collection of records.
      def agent_pool
        callable = agents
        return [] unless callable

        result = callable.call
        unless result.respond_to?(:each) || result.respond_to?(:to_a)
          raise ConfigurationError,
                "config.agents must return a relation or an array of agents, got #{result.inspect}"
        end

        result
      end

      # --- Topics ---------------------------------------------------------------

      # The desk's topic tree. With a block, remembers it; with none, builds
      # it (once) and hands it back.
      #
      # The block is kept rather than run immediately ON PURPOSE: an
      # initializer runs before the host's own classes are autoloadable, and
      # `topic :ride, about: Ride` has to keep reading like that. The tree is
      # built at the first prepare — still boot, so a malformed tree is still
      # a boot failure — and it stores class NAMES, so it survives reloads.
      def topics(&block)
        if block
          @topics_block = block
          @topics = nil
          return block
        end

        @topics ||= if @topics_block
                      TopicTree.build(&@topics_block)
        elsif fallback
                      fallback.topics
        else
                      TopicTree.build
        end
      end

      # Whether this desk declared a tree of its own.
      def own_topics? = !@topics_block.nil?

      # --- Behaviour ------------------------------------------------------------

      # Who may reply to a ticket somebody else holds: :anyone (the reply
      # posts, signed by the drop-in), :take_over (replying reassigns), or
      # :assignee_only (raises NotAllowed).
      def reply_policy = read(:reply_policy)

      # Set it, validating on assignment (see the reader above).
      def reply_policy=(value)
        @settings[:reply_policy] = ensure_one_of(value, REPLY_POLICIES, "reply_policy")
      end

      # Whether the requester is told who picked up their ticket: :first_only
      # (the first human to take it), :always (hand-offs too), or :never.
      def announce_assignments = read(:announce_assignments)

      # Set it, validating on assignment (see the reader above).
      def announce_assignments=(value)
        @settings[:announce_assignments] = ensure_one_of(value, ANNOUNCE_MODES, "announce_assignments")
      end

      # What a requester writing into a closed ticket does: :reopen_on_reply
      # (the ticket comes back) or :locked (the composer is replaced by a
      # notice).
      def closed_tickets = read(:closed_tickets)

      # Set it, validating on assignment (see the reader above).
      def closed_tickets=(value)
        @settings[:closed_tickets] = ensure_one_of(value, CLOSED_TICKET_MODES, "closed_tickets")
      end

      # The answer promise: the SLA breach threshold AND the "normalmente en
      # menos de 24 h" line the requester is shown. One setting, one truth.
      def reply_within = duration(read(:reply_within))

      # Set it, validating on assignment (see the reader above).
      def reply_within=(value)
        @settings[:reply_within] = ensure_duration(value, "reply_within")
      end

      # When a waiting ticket starts showing as at risk, short of breach.
      def at_risk_after = duration(read(:at_risk_after))

      # Set it, validating on assignment (see the reader above).
      def at_risk_after=(value)
        @settings[:at_risk_after] = ensure_duration(value, "at_risk_after")
      end

      # `{ to: 5, within: 1.hour }` — how often one requester may open
      # tickets. nil disables it.
      def open_rate_limit = read(:open_rate_limit)

      # Set it, validating on assignment (see the reader above).
      def open_rate_limit=(value)
        if value.nil?
          @settings[:open_rate_limit] = nil
          return
        end

        hash = value.to_h.symbolize_keys
        unless hash[:to].is_a?(Integer) && hash[:to].positive? && hash[:within].respond_to?(:to_i)
          raise ConfigurationError,
                "open_rate_limit must be nil or { to: Integer, within: duration }, got #{value.inspect}"
        end

        @settings[:open_rate_limit] = hash
      end

      # How many tickets one requester may have open at once. nil for no
      # cap. Advisory: checked before the insert, not under a lock, so a
      # burst of concurrent opens can leave a requester one over.
      def max_open_tickets = read(:max_open_tickets)

      # Set it, validating on assignment (see the reader above).
      def max_open_tickets=(value)
        unless value.nil? || (value.is_a?(Integer) && value.positive?)
          raise ConfigurationError, "max_open_tickets must be a positive Integer or nil, got #{value.inspect}"
        end

        @settings[:max_open_tickets] = value
      end

      # Whether the desk shows up in the requester's inbox before they have
      # ever written: :always (a "¿Necesitas ayuda?" door), :when_tickets,
      # or :never.
      def inbox_entry = read(:inbox_entry)

      # Set it, validating on assignment (see the reader above).
      def inbox_entry=(value)
        @settings[:inbox_entry] = ensure_one_of(value, INBOX_ENTRY_MODES, "inbox_entry")
      end

      # How new tickets find an agent. 0.1 ships :manual (unassigned, pool
      # notified, first take wins) and procs; the load-aware strategies
      # arrive with the duty table in 0.3.
      def routing = read(:routing)

      # Set it, validating on assignment (see the reader above).
      def routing=(value)
        if value.respond_to?(:call)
          @settings[:routing] = value
          return
        end

        strategy = ensure_one_of(value, ROUTING_STRATEGIES, "routing")
        if UNRELEASED_ROUTING_STRATEGIES.include?(strategy)
          raise ConfigurationError,
                "routing #{strategy.inspect} needs the duty and capacity tables that ship in support_desk 0.3 — " \
                "use :manual, or a ->(ticket) { agent } proc"
        end

        @settings[:routing] = strategy
      end

      # Whether agent replies are also emailed to the requester (0.2).
      def mirror_replies_by_email = read(:mirror_replies_by_email)

      # Set it, validating on assignment (see the reader above).
      def mirror_replies_by_email=(value)
        @settings[:mirror_replies_by_email] = ensure_one_of(value, MIRROR_MODES, "mirror_replies_by_email")
      end

      # Close a ticket that has been awaiting the requester this long (0.2).
      def auto_close_after = duration(read(:auto_close_after))

      # Set it, validating on assignment (see the reader above).
      def auto_close_after=(value)
        @settings[:auto_close_after] = ensure_duration(value, "auto_close_after")
      end

      # --- Internals ------------------------------------------------------------

      def read(name) # :nodoc:
        return @settings[name] if @settings.key?(name)
        return fallback.read(name) if fallback

        DEFAULTS[name]
      end

      # Whether THIS desk states the setting itself, rather than inheriting.
      def own?(name) = @settings.key?(name) # :nodoc:

      # Forget a setting so this desk inherits it again (tests).
      def reset_setting(name) # :nodoc:
        @settings.delete(name)
      end

      # The desk and what it calls itself.
      def inspect
        "#<SupportDesk::Configuration::DeskConfiguration #{key} #{name.inspect}>"
      end

      private

      def duration(value)
        return nil if value.nil?
        return value if value.is_a?(ActiveSupport::Duration)

        ActiveSupport::Duration.build(value.to_i)
      end

      def ensure_present_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} can't be blank" if string.strip.empty?

        string
      end

      def ensure_one_of(value, allowed, name)
        symbol = value.respond_to?(:to_sym) ? value.to_sym : value
        unless allowed.include?(symbol)
          raise ConfigurationError, "#{name} must be one of #{allowed.map(&:inspect).join(", ")}, got #{value.inspect}"
        end

        symbol
      end

      def ensure_duration(value, name)
        return nil if value.nil?

        unless value.is_a?(ActiveSupport::Duration) || value.is_a?(Numeric)
          raise ConfigurationError, "#{name} must be a duration (e.g. 24.hours) or nil, got #{value.inspect}"
        end

        value
      end

      def ensure_callable(value, name)
        unless value.respond_to?(:call)
          raise ConfigurationError, "#{name} must respond to #call (a proc/lambda), got #{value.inspect}"
        end

        value
      end

      # nil, a String, an I18n key, or something to call. A String is
      # interpolated here and now against the sample, so an unknown
      # placeholder fails at boot rather than inside a transaction.
      def ensure_line(value, name)
        return value if value.nil? || value.is_a?(Symbol) || value.respond_to?(:call)
        if value.is_a?(String)
          interpolate_line(value, LINE_INTERPOLATIONS, name)
          return value
        end

        raise ConfigurationError,
              "#{name} must be a String, an I18n key (Symbol), a block, or nil, got #{value.inspect}"
      end

      # Named interpolation, NOT String#%: "100% ready" is ordinary copy in
      # any language, and `%` would read that as a format directive and
      # raise. I18n.interpolate leaves a literal percent alone and only
      # touches %{named} placeholders.
      def interpolate_line(line, interpolations, name)
        I18n.interpolate(line, interpolations)
      rescue KeyError, ArgumentError => e
        raise ConfigurationError,
              "#{name} can't be interpolated (#{e.class}: #{e.message}). The placeholders it can use are " \
              "#{LINE_INTERPOLATIONS.keys.map { |key| "%{#{key}}" }.join(", ")}."
      end

      def line_interpolations(ticket)
        { label: ticket.label, desk: ticket.desk.name,
          reply_within: (SupportDesk.humanize_duration(reply_within) if reply_within) }
      end
    end

    # Settings that belong to a desk rather than the installation. The
    # top-level accessors forward to the `:default` desk, which is also what
    # every other desk falls back to.
    DESK_SETTINGS = %i[
      name avatar email opening_line opening_line_from_support find_requester reply_policy
      announce_assignments closed_tickets reply_within at_risk_after open_rate_limit max_open_tickets
      inbox_entry routing mirror_replies_by_email auto_close_after
    ].freeze

    delegate(*DESK_SETTINGS, *DESK_SETTINGS.map { |setting| :"#{setting}=" }, to: :default_desk)
    delegate :agents, :agents=, :topics, to: :default_desk

    # The model that asks for help — the one with `has_support_tickets`. It
    # must also be a chats messager: a requester holds a seat in the
    # conversation behind every one of their tickets.
    attr_reader :requester_class

    # The controller the requester-facing engine inherits from, so your
    # layout, helpers, auth and locale apply to the support screens.
    attr_reader :parent_controller

    # The controller the console inherits from (the optional ConsoleEngine
    # and the generated console) — usually your admin framework's base
    # controller.
    attr_reader :console_parent_controller

    # How the engine finds the person asking for help.
    attr_accessor :current_requester_method

    # How the console finds the person answering.
    attr_accessor :current_agent_method

    # The host's own authentication filter, run before every requester-facing
    # screen so a logged-out visitor meets the host's login flow rather than
    # this gem's idea of one (`:authenticate_user!` is Devise's, and chats'
    # default too).
    attr_accessor :authenticate_method
    # ->(agent) { … } returning the desks this agent may work, or nil for
    # "every desk". Read through #desks_visible_to.
    attr_reader :visible_desks_for

    # ->(agent, ticket, action) { true/false } — the console asks this before
    # every action, for hosts with Pundit, CanCan or a policy object of their
    # own. Read through #console_authorized?.
    attr_reader :authorize_console

    # A fresh configuration: one `:default` desk, every setting at the
    # documented default.
    def initialize
      @requester_class = "User"
      @parent_controller = "::ApplicationController"
      @console_parent_controller = "::ApplicationController"
      @current_requester_method = :current_user
      @current_agent_method = :current_user
      @authenticate_method = :authenticate_user!
      @visible_desks_for = nil
      @authorize_console = nil

      @desks = { default: DeskConfiguration.new(:default) }
      @warnings = []
    end

    def requester_class=(value)
      @requester_class = ensure_class_name(value, "requester_class")
    end

    def parent_controller=(value)
      @parent_controller = ensure_class_name(value, "parent_controller")
    end

    def console_parent_controller=(value)
      @console_parent_controller = ensure_class_name(value, "console_parent_controller")
    end

    # --- The console ------------------------------------------------------------

    # Narrow what the console can reach:
    #
    #   config.visible_desks_for = ->(agent) { agent.billing? ? [ SupportDesk.desk(:billing) ] : Desk.all }
    #
    # A ticket on a desk an agent can't see is a 404 in the console, not a
    # 403: an agent who may not work the billing desk shouldn't learn that a
    # billing case exists.
    def visible_desks_for=(value)
      @visible_desks_for = value.nil? ? nil : ensure_callable(value, "visible_desks_for")
    end

    # The desks +agent+ may work, always as Desk records. The hook may hand
    # back records, a relation, or plain desk keys — all three read the same
    # way in an initializer, so all three are accepted here.
    def desks_visible_to(agent)
      return Desk.all if visible_desks_for.nil?

      Array(visible_desks_for.call(agent)).filter_map do |desk|
        desk.is_a?(Desk) ? desk : SupportDesk.desk(desk)
      end
    end

    #   config.authorize_console = ->(agent, ticket, action) { AdminPolicy.new(agent).support?(action) }
    #
    # `ticket` is nil on collection actions (the index, "next"). Returning
    # false is a 403.
    def authorize_console=(value)
      @authorize_console = value.nil? ? nil : ensure_callable(value, "authorize_console")
    end

    # Whether the host's policy allows +agent+ to do +action+ here. True when
    # no hook is configured — the console's own agent check still applies.
    #
    # A hook that RAISES denies rather than taking the screen down with it.
    # This is the one place in the gem where swallowing an exception is the
    # right call: an authorization check that blew up has not said yes, and
    # a 500 on the page that was guarding something is both a worse answer
    # and a louder hint that something is there. The error still reaches the
    # host through `Rails.error`, so nobody has to notice it from a flash.
    def console_authorized?(agent, ticket, action)
      return true if authorize_console.nil?

      !!authorize_console.call(agent, ticket, action)
    rescue StandardError => e
      report_console_authorization_error(e, action)
      false
    end

    # --- Desks ------------------------------------------------------------------

    # Read or configure a desk:
    #
    #   config.desk :billing do |desk|
    #     desk.name = "Facturación"
    #   end
    #
    #   config.desk(:billing).reply_within   # => 24 hours (inherited)
    def desk(key = :default)
      key = key.to_sym
      configuration = @desks[key] ||= DeskConfiguration.new(key, fallback: default_desk)
      yield configuration if block_given?
      configuration
    end

    def default_desk = @desks[:default]

    # Every configured desk, keyed by key.
    def desks = @desks

    def desk?(key) = @desks.key?(key.to_sym)

    # --- Events -----------------------------------------------------------------

    # Subscribe from inside the configure block — the same dispatcher as
    # `SupportDesk.on`, spelled the way an initializer reads best.
    def on(event, &block)
      SupportDesk.on(event, &block)
    end

    # --- Validation -------------------------------------------------------------

    # Cross-field validation, run at the end of `SupportDesk.configure`.
    # Anything that needs the host's classes to be loaded is checked later,
    # in the engine's to_prepare hook (see #validate_classes!).
    def validate!
      @desks.each_value do |desk|
        next unless desk.at_risk_after && desk.reply_within && desk.at_risk_after > desk.reply_within

        raise ConfigurationError,
              "desk #{desk.key}: at_risk_after (#{desk.at_risk_after.inspect}) must come before " \
              "reply_within (#{desk.reply_within.inspect}) — a ticket can't breach before it's at risk"
      end

      true
    end

    # Warnings raised by the last `validate!` — surfaced by `doctor`.
    attr_reader :warnings

    # Checks that need the host's classes loaded, so they run from the
    # engine's to_prepare (every boot, and again after every reload).
    def validate_classes!
      requester = requester_class.safe_constantize
      unless requester
        raise ConfigurationError,
              "config.requester_class is #{requester_class.inspect}, which doesn't exist. " \
              "Point it at the model that asks for help."
      end

      unless requester.respond_to?(:support_desk_requester_options)
        raise ConfigurationError,
              "#{requester_class} must declare `has_support_tickets` (and `acts_as_messager`) to be the " \
              "requester_class."
      end

      validate_requester_desks!

      @warnings = []
      @desks.each_value do |desk|
        validate_agent_pool!(desk)
        # Reading the tree is what BUILDS it, so a malformed topics block
        # fails here — at boot, with the offending option named.
        tree = desk.topics

        tree.each do |topic|
          topic.about_class_names.each { |name| validate_supportable!(name, topic, desk) }
        end

        next if tree.empty? || tree.free_form?

        @warnings << "desk #{desk.key}: no free-form topic. Add `other` to the topics block — a taxonomy " \
                     "without an exit is how people pick the wrong topic."
      end
      @warnings.each { |warning| SupportDesk.logger&.warn("[support_desk] #{warning}") }

      true
    end

    # The constantized requester class (resolved lazily — see class comment).
    def requester_model = requester_class.constantize

    def parent_controller_class = parent_controller.constantize

    def console_parent_controller_class = console_parent_controller.constantize

    private

    # `config.agents { … }` has to hand back something a desk can iterate.
    # Resolving it costs nothing at boot — a relation is lazy — and a block
    # that returns 42, or raises, is a configuration mistake, not a 3am
    # surprise the first time somebody opens a ticket.
    def validate_agent_pool!(desk)
      return if desk.agents.nil?

      desk.agent_pool
    rescue ConfigurationError
      raise
    rescue ActiveRecord::ActiveRecordError
      # No database yet (asset precompile, a boot before migrating).
      # `SupportDesk.doctor` asks the same question where there is one.
      nil
    rescue StandardError => e
      raise ConfigurationError,
            "config.agents for desk #{desk.key} raised #{e.class}: #{e.message}"
    end

    # A model that writes to a desk nobody configured would quietly land its
    # tickets on the default desk instead.
    def validate_requester_desks!
      SupportDesk.requester_class_names.each do |name|
        klass = name.safe_constantize
        next unless klass.respond_to?(:support_desk_requester_options)

        key = klass.support_desk_requester_options[:desk]
        next if @desks.key?(key)

        raise ConfigurationError,
              "#{name} has `has_support_tickets desk: #{key.inspect}`, but no such desk is configured. " \
              "Add `config.desk #{key.inspect} do |desk| … end`, or drop the desk: option."
      end
    end

    def validate_supportable!(name, topic, desk)
      klass = name.safe_constantize
      unless klass
        raise ConfigurationError,
              "desk #{desk.key}, topic #{topic.path.inspect}: about: #{name} doesn't exist."
      end

      return if klass.respond_to?(:supportable?) && klass.supportable?

      raise ConfigurationError,
            "desk #{desk.key}, topic #{topic.path.inspect}: about: #{name} is not supportable. " \
            "Add `supportable topic: :#{topic.path}` to #{name}."
    end

    def ensure_class_name(value, name)
      string = value.is_a?(Class) ? value.name : value.to_s
      raise ConfigurationError, "#{name} can't be blank" if string.strip.empty?

      string
    end

    def ensure_callable(value, name)
      unless value.respond_to?(:call)
        raise ConfigurationError, "#{name} must respond to #call (a proc/lambda), got #{value.inspect}"
      end

      value
    end

    # The same reporting path the event dispatcher uses for a subscriber
    # that raises: `Rails.error` when there is one, the log otherwise.
    def report_console_authorization_error(error, action)
      if defined?(Rails) && Rails.respond_to?(:error) && Rails.error
        Rails.error.report(error, handled: true, source: "support_desk",
                                  context: { hook: :authorize_console, action: action })
      else
        SupportDesk.logger&.error("[support_desk] authorize_console raised on #{action}: " \
                                  "#{error.class}: #{error.message}")
      end
    end
  end
end
