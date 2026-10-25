# frozen_string_literal: true

module SupportDesk
  # The desk: who answers, as far as the requester is concerned.
  #
  # A desk is a chats messager — a headless one. It has no notifications of
  # its own (agents are notified through the host's own fan-out, never by
  # this gem) and can't be blocked or reported as a person, because it isn't
  # one. Its conversations collapse into a single grouped inbox row, so
  # somebody with four open tickets sees "Soporte" once, not four times.
  #
  # It is also a VERIFIED messager: a desk is the official voice of the
  # product, and the person writing to it should be able to tell that from
  # an impostor without reading the name carefully. chats badges it wherever
  # it shows a messager's name.
  #
  #   SupportDesk.desk            # the :default desk, memoised
  #   SupportDesk.desk(:billing)  # another one
  #
  # Rows are created lazily and never INSERT-first: a desk is read on every
  # page and written once in its life.
  #
  # An app that runs a desk per customer gives each one an OWNER (any
  # record: an account, a workspace, a product). The key stays the same —
  # every owner has a `:default` desk — and SupportDesk::Current.owner says
  # whose is meant. A desk with no owner is the single-desk app.
  class Desk < ApplicationRecord
    self.table_name = "support_desk_desks"

    belongs_to :owner, polymorphic: true, optional: true

    # nil, rather than a MissingAttributeError, until the 0.6 migration has
    # added the column: an unmigrated install has no owners.
    def owner = has_attribute?(:owner_id) ? super : nil

    acts_as_messager notifications: false,
                     blockable: false,
                     inbox: :grouped,
                     verified: true,
                     group_path: ->(_viewer) { SupportDesk.root_path }

    has_many :tickets,
             class_name: "SupportDesk::Ticket",
             inverse_of: :desk,
             dependent: :restrict_with_error

    # Ruby-side default so settings is always a Hash even on MySQL, where a
    # JSON column can't carry a DB default.
    attribute :settings, default: -> { {} }

    validates :key, presence: true

    # The desk for +key+, found or created. Never INSERT-first: `find_by`
    # answers from the index on every call but the very first.
    #
    # `SupportDesk.desk` then memoises the record FOR THE LIFE OF THE
    # PROCESS, so a `settings` change written by another process (a console,
    # another web worker) is not picked up until this one boots again or
    # somebody calls `SupportDesk.reset_desks!`. That is the trade the
    # performance requirement asks for — a desk is read on every page and
    # written once in its life — and it is why configuration, not
    # `settings`, is the place to put anything that has to change together
    # everywhere.
    def self.for(key, owner: nil)
      key = key.to_s
      scope = owned_by(owner)
      scope.find_by(key: key) || scope.create_or_find_by!(key: key)
    end

    # The desks that belong to +owner+; nil means the desks that belong to
    # nobody. Before the 0.6 migration there is no owner to ask about, and
    # every desk belongs to nobody.
    def self.owned_by(owner)
      return all if owner.nil? && !column_names.include?("owner_id")

      where(owner: owner)
    end

    # This desk's slice of the configuration: the initializer's, overlaid
    # with what `config.desk_settings` says about this row when the host
    # set one. Read once per record — see SupportDesk.desk for how long a
    # record lives.
    def config
      return SupportDesk.config.desk(key) if SupportDesk.config.desk_settings.nil?

      @config ||= SupportDesk.config.desk_configuration_for(self)
    end

    # A reloaded desk reads its settings again.
    def reload(*)
      @config = nil
      super
    end

    # What requesters see as the counterpart. Configuration wins; the
    # `settings` column is the runtime fallback for hosts that let staff
    # rename a desk from a console.
    def name
      config.read(:name) || settings["name"].presence || key.to_s.humanize
    end
    alias display_name name

    # Anything `image_tag` accepts, or nil. A callable is passed the desk.
    def avatar
      value = config.read(:avatar) || settings["avatar"].presence
      value.respond_to?(:call) ? value.call(self) : value
    end

    # The address the email channel answers from (0.2).
    def email
      config.read(:email) || settings["email"].presence
    end

    # The assistant who works this desk, or nil: the one with this desk's
    # owner, whatever SupportDesk::Current.owner says. Resolved through
    # `SupportDesk.assistant`, so it is the same memoised record everywhere.
    def assistant
      key = config.assistant_key
      return nil if key.nil?

      SupportDesk.assistant(key, owner: owner)
    end

    # Whether this desk has one at all.
    def assistant? = !assistant.nil?

    # The PEOPLE in the pool. What `agents_to_notify` pages, what a human
    # picker offers, and the reason a host never has to reject machines in
    # its own notifier.
    def humans
      config.agent_pool.to_a.reject { |agent| SupportDesk.ai_actor?(agent) }
    end

    # Everybody who can answer here, the assistant included — pickers and
    # routing. An Array, not a relation: the assistant isn't in the host's
    # scope, and a pool that is half a query and half a record is a pool
    # that can't be either.
    def agents
      humans + [ assistant ].compact
    end

    # The pool, minus anyone who says they're off duty (a deactivated
    # assistant says so).
    def on_duty_agents
      agents.select { |agent| !agent.respond_to?(:on_duty?) || agent.on_duty? }
    end

    # Whether +record+ may answer this desk's tickets.
    def agent?(record)
      return false if record.nil? || record.is_a?(Symbol)

      record.respond_to?(:support_agent?) && record.support_agent?
    end

    # A desk prints as its name — it's a counterpart, not a row.
    def to_s = name

    # The desk, in one line.
    def inspect
      "#<SupportDesk::Desk #{key} #{name.inspect}#{" #{owner_type}##{owner_id}" if try(:owner_id)}>"
    end
  end
end
