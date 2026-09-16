# frozen_string_literal: true

module SupportDesk
  # The append-only timeline of everything that is not a message: who took
  # the ticket, who handed it off, who closed it, what an agent noted.
  #
  # Rows are written inside the same transaction as the transition they
  # describe — exactly one row per transition — and are read-only forever
  # after. Hosts with tamper-evident logs mirror them by subscribing to
  # `:ticket_transitioned` rather than by writing here.
  class Event < ApplicationRecord
    self.table_name = "support_desk_events"

    KINDS = %w[
      opened assigned handed_off released drop_in closed reopened topic_changed subject_attached note
      snoozed woken escalated channel_added email_bounced email_unverified rated tagged
    ].freeze

    belongs_to :ticket, class_name: "SupportDesk::Ticket", inverse_of: :events
    belongs_to :actor, polymorphic: true, optional: true

    attribute :payload, default: -> { {} }

    validates :kind, inclusion: { in: KINDS }

    scope :chronological, -> { order(:created_at, :id) }
    scope :of_kind, ->(*kinds) { where(kind: kinds.flatten.map(&:to_s)) }
    scope :notes, -> { where(kind: "note") }
    # Everything a requester may see in an export: their own case's story,
    # never the desk's internal reasoning.
    scope :requester_visible, -> { where.not(kind: %w[note drop_in]) }

    # Write one event. `actor` may be a record or a Symbol (`:system`,
    # `:routing`) — symbols are kept in the payload, since there is no row
    # to point at.
    def self.record!(ticket:, kind:, actor: nil, payload: {})
      create!(
        ticket: ticket,
        kind: kind.to_s,
        actor: actor.is_a?(Symbol) || actor.nil? ? nil : actor,
        payload: payload.merge(actor.is_a?(Symbol) ? { "by" => actor.to_s } : {})
      )
    end

    # Append-only, enforced the way ActiveRecord can enforce it: a loaded
    # event refuses `update!`, `update_column` and friends.
    #
    # It is NOT tamper-proofing. `update_all` and `delete_all` never
    # instantiate a record, so they bypass this exactly as they bypass every
    # other model-level rule, and anything with database access can rewrite
    # a row regardless. A host that needs tamper EVIDENCE mirrors
    # `:ticket_transitioned` into its own hash-chained log; this guarantees
    # that the gem, and code using the gem's models, only ever appends.
    def readonly?
      persisted?
    end

    # Who acted, as something you can print: the actor record, or the
    # symbol kept in the payload.
    def actor_or_system
      actor || payload["by"]&.to_sym
    end

    # The text of an internal note, for kind "note".
    def note = payload["note"]

    # The event, in one line.
    def inspect
      "#<SupportDesk::Event #{kind} ticket=#{ticket_id} #{created_at&.iso8601}>"
    end
  end
end
