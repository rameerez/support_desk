# frozen_string_literal: true

module SupportDesk
  # The assistant: an AI agent, as a record.
  #
  #   rose = SupportDesk.assistant(:rose)
  #   rose.autonomy        # => :draft      (from configuration)
  #   rose.deactivate!(by: lucia)           # the cross-process kill switch
  #
  # Two things live here and nothing else: WHO she is (a row a message can
  # be authored by, an assignment can point at, and an audit log can name)
  # and WHETHER she is on. Everything she may do lives in configuration, in
  # code, so a policy change is a deploy and a diff — see
  # SupportDesk::Configuration::AssistantConfiguration and
  # SupportDesk::AssistantPolicy.
  #
  # `active` is the one runtime switch, and it is a DATABASE column on
  # purpose: `rose.deactivate!(by: owner)` stops her everywhere within one
  # transition, with no deploy, because `ensure_agent_record!` re-reads this
  # row before every write. Rows are never destroyed — a case she answered in
  # March must still be able to say who wrote it.
  class Assistant < ApplicationRecord
    self.table_name = "support_desk_assistants"

    acts_as_support_agent kind: :ai, if: :active?

    # Ruby-side default so settings is always a Hash even on MySQL, where a
    # JSON column can't carry a DB default.
    attribute :settings, default: -> { {} }

    validates :key, presence: true

    scope :active, -> { where(active: true) }

    # The assistant for +key+, found or created. Never INSERT-first, exactly
    # like Desk.for: read on every transition, written once.
    def self.for(key)
      key = key.to_s
      find_by(key: key) || create_or_find_by!(key: key)
    end

    # --- Configuration ----------------------------------------------------------

    # Her slice of the configuration. Raises ConfigurationError when nothing
    # declares her any more — which is why everything below reads through
    # #settings_config and falls back to the safest answer instead.
    def config
      SupportDesk.config.assistant(key)
    end

    # Whether this row still has configuration behind it. False for an
    # assistant a host removed from the initializer and kept the history of.
    def configured? = SupportDesk.config.assistant?(key)

    def name = settings_config&.name || key.to_s.humanize

    # Anything `image_tag` accepts, or nil. A callable is passed the record.
    def avatar
      value = settings_config&.avatar
      value.respond_to?(:call) ? value.call(self) : value
    end

    # An unconfigured assistant is capped at :off by construction: there is
    # no rule left saying what she may do, so she may do nothing.
    def autonomy = settings_config&.autonomy || :off
    def disclosure = settings_config&.disclosure
    def max_turns = settings_config&.max_turns
    def responds_within = settings_config&.responds_within
    def may_open_conversations? = settings_config&.may_open_conversations? || false

    def disclosed? = settings_config ? settings_config.disclosed? : false
    def signs? = settings_config ? settings_config.signs? : false
    def notice? = settings_config ? settings_config.notice? : false

    # --- Who she looks like -----------------------------------------------------

    # The name a REQUESTER sees. Disclosure is not a badge somebody might
    # miss: when she discloses, the name itself says what she is.
    def disclosed_name
      return name unless disclosed?

      I18n.t("support_desk.assistant.disclosed_name", name: name)
    end

    # chats reads a display name through the host's own lambda, which
    # usually tries these in order — so all three answer the disclosed name
    # and no host has to special-case a support assistant.
    def display_name = disclosed_name
    def to_s = disclosed_name
    def support_agent_name = disclosed_name
    def support_agent_avatar = avatar

    # --- Duty -------------------------------------------------------------------

    # The kill switch, read fresh from the row on every transition.
    def on_duty? = active?

    # Unlimited by construction: her ceiling is `max_turns` per case and the
    # policy, not a number of cases.
    def support_capacity = nil

    # Stop her everywhere, now. The cases she is SITTING on are given back by
    # `SupportDesk.reclaim_assistant_seats!` (which
    # `release_silent_assistants!` runs first, and
    # `rake support_desk:reclaim_assistant_seats` runs alone), and it asks
    # for a person on each of them. Run it, or wait for its schedule, before
    # calling the desk quiet.
    #
    # It needs no `responds_within` and no overdue clock: a seat nobody can
    # sit in any more is not a silence problem. In 0.3.0 it was treated as
    # one, so an assistant with no promise kept her seats for ever (R6).
    def deactivate!(by:, reason: nil)
      update!(active: false)
      SupportDesk.logger&.warn(
        "[support_desk] assistant #{key} deactivated by #{SupportDesk.actor_key(by) || "somebody"}" \
        "#{": #{reason}" if reason.present?}"
      )
      self
    end

    # Put her back on duty.
    def activate!(by:)
      update!(active: true)
      SupportDesk.logger&.info(
        "[support_desk] assistant #{key} activated by #{SupportDesk.actor_key(by) || "somebody"}"
      )
      self
    end

    # --- Where she works --------------------------------------------------------

    # The desks whose configuration points at her.
    def desks
      SupportDesk.config.desks.each_key.filter_map do |desk_key|
        SupportDesk.desk(desk_key) if SupportDesk.config.desk(desk_key).assistant_key == key.to_sym
      end
    end

    # The open cases she is sitting on.
    def held_tickets
      Ticket.open.assigned_to(self)
    end

    # The assistant, in one line.
    def inspect
      "#<SupportDesk::Assistant #{key} #{name.inspect} #{autonomy} #{active? ? "active" : "inactive"}>"
    end

    private

    # Her configuration, or nil when nothing declares her any more. Every
    # reader goes through this so a historical row still renders.
    def settings_config
      return nil unless configured?

      config
    end
  end
end
