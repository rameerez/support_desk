# frozen_string_literal: true

require "active_model/type"

module SupportDesk
  # What a ticket is about, as a value object.
  #
  # Topics are a tree defined in code (see SupportDesk::TopicTree), frozen at
  # boot, and stored on the ticket as a stable path — `"payments/withdrawal"`
  # — so seeds, exports and metrics stay readable and re-ordering the tree
  # never rewrites a single row.
  #
  #   ticket.topic                      # => #<SupportDesk::Topic payments/withdrawal>
  #   ticket.topic == :ride             # compares against the path
  #   ticket.topic.under?(:payments)    # self or any descendant
  #   ticket.topic.label                # "Una retirada" (i18n)
  #   ticket.topic.to_s                 # "payments/withdrawal"
  #
  # Immutable: every node is frozen once the tree is built.
  class Topic
    # Options a branch passes down to its descendants unless they say
    # otherwise. Presentation (label, ask, prefill) is never inherited — only
    # the options that carry behaviour.
    INHERITED_OPTIONS = %i[about candidates desk route_to priority only retired].freeze

    SUBJECT_MODES = %i[required optional none].freeze
    PRIORITIES = { normal: 0, high: 1, urgent: 2 }.freeze

    attr_reader :key, :path, :parent, :children, :options

    def initialize(key:, parent: nil, **options)
      @key = key.to_sym
      @parent = parent
      @path = [parent&.path, @key].compact.join("/")
      @options = options.freeze
      @children = []
    end

    # --- Tree shape -----------------------------------------------------------

    def root? = parent.nil?
    def leaf? = children.empty?
    def branch? = !leaf?

    # Every ancestor, closest first.
    def ancestors
      parent ? [ parent, *parent.ancestors ] : []
    end

    # This node and every node below it, depth first.
    def self_and_descendants
      [ self, *children.flat_map(&:self_and_descendants) ]
    end

    # --- Identity -------------------------------------------------------------

    def to_s = path
    def to_param = path

    # True for the null object returned for paths that aren't in the tree.
    def unknown? = false

    # Compares against a Topic, a path String, or a Symbol key/path, so
    # `ticket.topic == :ride` reads the way you'd say it.
    def ==(other)
      case other
      when Topic then path == other.path
      when String, Symbol then path == other.to_s
      else false
      end
    end
    alias eql? ==

    def hash = path.hash

    # True when this topic is +other+ or lives under it:
    # `topic("payments/withdrawal").under?(:payments)`.
    def under?(other)
      other = other.to_s
      path == other || path.start_with?("#{other}/")
    end

    # --- Presentation ---------------------------------------------------------

    # The human name of this node, from `label:` or i18n
    # (`support_desk.topics.<dotted path>.label`), falling back to a
    # humanized key so a missing translation is never a missing screen.
    def label
      case options[:label]
      when String then options[:label]
      when Symbol then translate(i18n_key_for(options[:label], :label)) || key.to_s.humanize
      else translate(i18n_key(:label)) || key.to_s.humanize
      end
    end

    # The whole branch spelled out: "Pagos › Una retirada".
    def full_label
      [ *ancestors.reverse, self ].map(&:label).join(" › ")
    end

    # The picker prompt ("¿Con qué viaje necesitas ayuda?").
    def ask
      options[:ask].is_a?(String) ? options[:ask] : translate(i18n_key(:ask))
    end

    # The composer placeholder for tickets opened under this topic.
    def placeholder
      options[:placeholder].is_a?(String) ? options[:placeholder] : translate(i18n_key(:placeholder))
    end

    # Deterministic text dropped into the composer. `prefill:` may be a String
    # or a callable taking the chosen subject.
    def prefill(subject = nil)
      value = options[:prefill]
      value.respond_to?(:call) ? value.call(subject) : value
    end

    # An optional icon key for hosts that render one; the gem never does.
    def icon = options[:icon]

    # --- Behaviour ------------------------------------------------------------

    # The `supportable` classes a ticket under this topic may attach, as
    # Classes. Resolved lazily from stored names so the tree survives
    # Zeitwerk reloads.
    def about
      Array(inherited_or_own(:about)).map { |klass| klass.is_a?(String) ? klass.constantize : klass }
    end

    def about?(klass)
      about.any? { |candidate| klass.is_a?(Class) ? klass <= candidate : klass.class <= candidate }
    end

    # Stored (unconstantized) `about:` class names — what boot validation and
    # `doctor` check, without forcing the classes to load.
    def about_class_names
      Array(inherited_or_own(:about)).map { |klass| klass.is_a?(String) ? klass : klass.name }
    end

    # :required — the wizard insists on a subject; :optional — it offers
    # "none of these"; :none — free form. Defaults to :optional when the
    # topic attaches anything at all, :none when it doesn't.
    def subject_mode
      options.fetch(:subject) { about.any? ? :optional : :none }.to_sym
    end

    def subject_required? = subject_mode == :required
    def free_form? = subject_mode == :none

    # The picker's candidate records for +requester+: the topic's
    # `candidates:` proc, else each `about:` class's own
    # `.support_candidates_for`.
    def candidates_for(requester)
      proc = inherited_or_own(:candidates)
      return proc.call(requester) if proc.respond_to?(:call)

      about.first&.support_candidates_for(requester)
    end

    # Whether this node shows in the wizard for +requester+ (`only:` proc,
    # and retired nodes never do).
    def visible_for?(requester)
      return false if retired?

      only = inherited_or_own(:only)
      only.respond_to?(:call) ? !!only.call(requester) : true
    end

    # 0 normal, 1 high, 2 urgent — the integer a ticket is opened with.
    def priority
      PRIORITIES.fetch((inherited_or_own(:priority) || :normal).to_sym, 0)
    end

    # An agent scope or proc that wins over desk routing for this subtree.
    def route_to = inherited_or_own(:route_to)

    # The desk key tickets under this topic belong to.
    def desk_key
      (inherited_or_own(:desk) || :default).to_sym
    end

    # Hidden from the wizard; the label still resolves for historic tickets.
    def retired? = !!inherited_or_own(:retired)

    def inspect = "#<SupportDesk::Topic #{path}>"

    # Freeze this node and everything under it — the tree is built once, at
    # boot, and then it is a value.
    def deep_freeze # :nodoc:
      children.each(&:deep_freeze)
      children.freeze
      freeze
    end

    def add_child(child) # :nodoc:
      children << child
      child
    end

    private

    def inherited_or_own(option)
      return options[option] if options.key?(option)
      return nil unless INHERITED_OPTIONS.include?(option)

      parent&.send(:inherited_or_own, option)
    end

    def i18n_key(suffix)
      "support_desk.topics.#{path.tr("/", ".")}.#{suffix}"
    end

    def i18n_key_for(symbol, suffix)
      symbol.to_s.include?(".") ? symbol.to_s : "support_desk.topics.#{symbol}.#{suffix}"
    end

    def translate(key)
      return nil unless defined?(I18n)

      I18n.t(key, default: nil)
    end

    # The null object for a path no tree knows: a retired node whose label
    # still reads well, so a historic ticket never blows up a view.
    #
    #   ticket.topic.unknown?   # => true
    #   ticket.topic.label      # => "Payments/withdrawal"
    class Unknown < Topic
      def initialize(path)
        super(key: path.to_s.split("/").last || path.to_s)
        @path = path.to_s
      end

      def unknown? = true
      def retired? = true
      def label = translate(i18n_key(:label)) || @path.tr("/", " ").humanize
      def about = []
      def subject_mode = :none
      def inspect = "#<SupportDesk::Topic::Unknown #{path}>"
    end

    # The ActiveModel attribute type behind `attribute :topic`: casts
    # Symbol | String | Topic on the way in, hands back a Topic on the way
    # out, and serializes to the path — so `where(topic: :ride)` works and a
    # view never sees a bare string.
    class Type < ActiveModel::Type::Value
      def type = :string

      def cast(value)
        case value
        when nil then nil
        when Topic then value
        else SupportDesk.find_topic(value.to_s)
        end
      end

      def serialize(value)
        case value
        when nil then nil
        when Topic then value.path
        else value.to_s
        end
      end

      def deserialize(value) = cast(value)

      def changed_in_place?(raw_old_value, new_value)
        raw_old_value != serialize(new_value)
      end
    end
  end
end
