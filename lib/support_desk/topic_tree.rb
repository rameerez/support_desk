# frozen_string_literal: true

require_relative "topic"

module SupportDesk
  # The tree of topics a desk offers, built once at boot from the `topics`
  # block and frozen:
  #
  #   config.topics do
  #     topic :ride, about: Ride
  #     topic :payments do
  #       topic :withdrawal, about: Payouts::Withdrawal
  #     end
  #     other
  #   end
  #
  # It is the one object the wizard, the console picker, routing and metrics
  # all read: `tree.find("payments/withdrawal")`, `tree.visible_for(user)`,
  # `tree.leaves`.
  class TopicTree
    include Enumerable

    # The free-form leaf every tree should have — a taxonomy without an exit
    # is how people pick the wrong topic.
    OTHER_KEY = :other

    attr_reader :roots

    def self.build(&block)
      new.tap { |tree| Builder.new(tree).instance_eval(&block) if block }.freeze!
    end

    def initialize
      @roots = []
      @index = {}
    end

    # Depth-first over every node.
    def each(&block)
      return to_enum(:each) unless block

      @roots.each { |root| root.self_and_descendants.each(&block) }
      self
    end

    # The node at +path+ ("payments/withdrawal"), or nil.
    def find(path)
      return nil if path.nil?

      @index[path.to_s]
    end
    alias [] find

    # The node at +path+, or raise SupportDesk::UnknownTopic.
    def find!(path)
      find(path) || raise(UnknownTopic, "no topic #{path.inspect} in this desk's tree " \
                                        "(known: #{@index.keys.sort.join(", ")})")
    end

    # Whether the tree has a node at +path+.
    def include?(path) = !find(path).nil?

    # Every node a ticket can actually be filed under.
    def leaves = select(&:leaf?)

    # A desk with no topics at all: every ticket lands free-form.
    def empty? = @roots.empty?

    # How many nodes, branches included.
    def size = count

    # The nodes a requester may see at a given level: pass nothing for the
    # top level, a node (or its path) to walk into a branch.
    def visible_for(requester, under: nil)
      nodes = under ? Array(find(under.to_s)&.children) : @roots
      nodes.select { |node| node.visible_for?(requester) }
    end

    # True when the tree has somewhere to put "something else": a leaf
    # DECLARED as the way out, with `other` or `free_form: true`.
    #
    # Not "any leaf that takes no subject" — a tree can be full of
    # subject-less topics ("safety", "feedback") and still have no honest
    # answer to "none of the above", which is the failure this guards.
    def free_form?
      !free_form_leaf.nil?
    end

    # The leaf a ticket lands on when nobody picked a topic.
    def free_form_leaf
      candidates = leaves.select { |leaf| leaf.catch_all? && !leaf.retired? }
      candidates.find { |leaf| leaf.key == OTHER_KEY } || candidates.first
    end

    # Every `about:` class name mentioned anywhere in the tree — what boot
    # validation and `doctor` check against the supportable registry.
    def about_class_names
      flat_map(&:about_class_names).uniq
    end

    def add(node, parent: nil) # :nodoc:
      parent ? parent.add_child(node) : @roots << node
      @index[node.path] = node
      node
    end

    def remove(path) # :nodoc:
      node = @index.delete(path.to_s)
      return nil unless node

      (node.parent ? node.parent.children : @roots).delete(node)
      node
    end

    def freeze! # :nodoc:
      @roots.each(&:deep_freeze)
      @roots.freeze
      @index.freeze
      freeze
    end

    def inspect = "#<SupportDesk::TopicTree #{map(&:path).join(" ")}>"

    # The `topic` / `other` DSL. It runs once, at boot, inside
    # `config.topics do … end` — no metaprogramming, nothing to grep for
    # later: every node you can see in the initializer is every node there is.
    class Builder
      def initialize(tree, parent: nil)
        @tree = tree
        @parent = parent
      end

      # Declare a node. With a block it's a branch and the block declares its
      # children; without one it's a leaf. See SupportDesk::Topic for every
      # option (`about:`, `ask:`, `candidates:`, `subject:`, `prefill:`,
      # `placeholder:`, `only:`, `priority:`, `route_to:`, `desk:`,
      # `retired:`, `icon:`, `label:`).
      def topic(key, **options, &block)
        validate!(key, options)

        node = Topic.new(key: key, parent: @parent, **normalize(options))
        @tree.add(node, parent: @parent)
        Builder.new(@tree, parent: node).instance_eval(&block) if block
        node
      end

      # The free-form leaf ("Otra cosa"). `other false` removes it — the gem
      # warns at boot when a tree ends up without one. A host that wants a
      # differently named way out declares that leaf `free_form: true`.
      def other(enabled = true, **options)
        return @tree.remove(TopicTree::OTHER_KEY.to_s) unless enabled

        topic(TopicTree::OTHER_KEY, subject: :none, free_form: true, **options)
      end

      private

      KNOWN_OPTIONS = %i[
        label about ask candidates subject prefill placeholder only priority route_to desk retired icon
        free_form
      ].freeze

      def validate!(key, options)
        unless key.is_a?(Symbol) || key.is_a?(String)
          raise ConfigurationError, "topic keys must be symbols, got #{key.inspect}"
        end

        unknown = options.keys - KNOWN_OPTIONS
        if unknown.any?
          raise ConfigurationError,
                "unknown topic option#{"s" if unknown.size > 1} #{unknown.map(&:inspect).join(", ")} " \
                "on topic #{key.inspect} — known options are #{KNOWN_OPTIONS.map(&:inspect).join(", ")}"
        end

        if options.key?(:subject) && !Topic::SUBJECT_MODES.include?(options[:subject].to_sym)
          raise ConfigurationError,
                "topic #{key.inspect}: subject must be one of #{Topic::SUBJECT_MODES.inspect}, " \
                "got #{options[:subject].inspect}"
        end

        if options.key?(:priority) && !Topic::PRIORITIES.key?(options[:priority].to_sym)
          raise ConfigurationError,
                "topic #{key.inspect}: priority must be one of #{Topic::PRIORITIES.keys.inspect}, " \
                "got #{options[:priority].inspect}"
        end

        %i[candidates only prefill].each do |option|
          next unless options.key?(option)
          next if option == :prefill && options[option].is_a?(String)
          next if options[option].respond_to?(:call)

          raise ConfigurationError,
                "topic #{key.inspect}: #{option} must respond to #call, got #{options[option].inspect}"
        end
      end

      # Store `about:` as class NAMES so the tree survives Zeitwerk reloads
      # and the initializer can name classes that haven't loaded yet.
      def normalize(options)
        options = options.dup
        if options.key?(:about)
          options[:about] = Array(options[:about]).map { |klass| klass.is_a?(Class) ? klass.name : klass.to_s }
        end
        options
      end
    end
  end
end
