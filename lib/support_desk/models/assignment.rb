# frozen_string_literal: true

module SupportDesk
  # Who held a ticket, when, and why they stopped. Assignment is a history,
  # not a column: hand-offs, drop-in take-overs, shift releases and "time
  # per agent" are unanswerable from a single `assignee_id`.
  #
  # `ticket.assignee` is the denormalised pointer to the one row with
  # `released_at IS NULL`; the two are written together inside one
  # transaction, and `SupportDesk.doctor` checks they still agree.
  class Assignment < ApplicationRecord
    self.table_name = "support_desk_assignments"

    REASONS = %w[taken assigned handed_off routed drop_in_takeover escalated reopened].freeze
    RELEASE_REASONS = %w[handed_off released shift_end closed escalated].freeze

    belongs_to :ticket, class_name: "SupportDesk::Ticket", inverse_of: :assignments
    belongs_to :agent, polymorphic: true
    belongs_to :assigned_by, polymorphic: true, optional: true

    validates :reason, inclusion: { in: REASONS }
    validates :release_reason, inclusion: { in: RELEASE_REASONS }, allow_nil: true

    scope :open, -> { where(released_at: nil) }
    scope :released, -> { where.not(released_at: nil) }
    scope :chronological, -> { order(:assigned_at, :id) }
    scope :for_agent, ->(agent) { where(agent: agent) }

    # Hand the ticket to +agent+: closes whoever held it and opens a new
    # row. The caller holds the ticket's row lock (every transition does),
    # which is what makes "at most one open assignment" true rather than
    # hopeful — the partial unique index is the belt underneath it.
    def self.open!(ticket:, agent:, by: nil, reason: :assigned, note: nil, release_reason: nil)
      open.where(ticket: ticket).each do |assignment|
        assignment.release!(reason: release_reason || default_release_reason(reason))
      end

      create!(
        ticket: ticket,
        agent: agent,
        assigned_by: by.is_a?(Symbol) ? nil : by,
        reason: reason.to_s,
        note: note,
        assigned_at: Time.current
      )
    end

    # What the previous holder's row records when a new one opens.
    def self.default_release_reason(reason)
      case reason.to_s
      when "handed_off" then "handed_off"
      when "escalated" then "escalated"
      else "released"
      end
    end

    def open? = released_at.nil?
    def released? = !open?

    # Close this row. Idempotent: releasing a released assignment changes
    # nothing.
    def release!(reason: :released)
      return self unless open?

      update!(released_at: Time.current, release_reason: reason.to_s)
      self
    end

    # How long this agent held the ticket (so far).
    def held_for
      return nil if assigned_at.nil?

      ActiveSupport::Duration.build(((released_at || Time.current) - assigned_at).to_i)
    end

    def inspect
      "#<SupportDesk::Assignment ticket=#{ticket_id} agent=#{agent_type}##{agent_id} " \
        "#{reason}#{" released:#{release_reason}" if released?}>"
    end
  end
end
