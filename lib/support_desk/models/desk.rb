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
  #   SupportDesk.desk            # the :default desk, memoised
  #   SupportDesk.desk(:billing)  # another one
  #
  # Rows are created lazily and never INSERT-first: a desk is read on every
  # page and written once in its life.
  class Desk < ApplicationRecord
    self.table_name = "support_desk_desks"

    acts_as_messager notifications: false,
                     blockable: false,
                     inbox: :grouped,
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
    def self.for(key)
      key = key.to_s
      find_by(key: key) || create_or_find_by!(key: key)
    end

    # This desk's slice of the configuration.
    def config
      SupportDesk.config.desk(key)
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

    # The agent pool, resolved from `config.agents`.
    def agents
      config.agent_pool
    end

    # The pool, minus anyone who says they're off duty.
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

    def inspect
      "#<SupportDesk::Desk #{key} #{name.inspect}>"
    end
  end
end
