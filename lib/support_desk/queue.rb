# frozen_string_literal: true

module SupportDesk
  # An agent's view of a desk: the tabs, the counts, the badge, and what to
  # work on next. Plain relations all the way down, so any UI — a console, a
  # rake task, a Slack command — renders from the same object.
  #
  #   q = lucia.support_queue
  #   q.awaiting          # the "needs an answer" tab, as a relation
  #   q.counts            # { mine: 2, unassigned: 3, … } in ONE query
  #   q.badge             # the nav number
  #   q.next              # the ticket to open now
  #   q.tabs              # [[:awaiting, "Pendientes", 4], …]
  class Queue
    # The tabs a console renders, in display order.
    TABS = %i[awaiting mine unassigned open snoozed closed].freeze

    # How long a nav badge may lie. Long enough that a busy console isn't
    # counting rows on every request, short enough that nobody notices.
    BADGE_TTL = 30

    attr_reader :agent, :desk

    # The queue for +agent+ on +desk+ (the default desk when omitted).
    def self.for(agent, desk: nil)
      new(agent, desk: desk || SupportDesk.desk)
    end

    def initialize(agent, desk:)
      @agent = agent
      @desk = desk
    end

    # --- Relations ---------------------------------------------------------------

    # Every ticket on this desk, newest first.
    def all
      Ticket.where(desk: desk).newest_first
    end

    # Open and held by this agent.
    def mine
      all.open.assigned_to(agent)
    end

    # Open and held by nobody.
    def unassigned
      all.open.unassigned
    end

    # Open and waiting on the desk — the tab that means "work".
    def awaiting
      all.open.awaiting_reply
    end

    # Put aside until a date (0.2).
    def snoozed = all.snoozed

    # Every live case on this desk, held or not.
    def open = all.open

    # Done, most recently touched first.
    def closed = all.closed.recent_activity_first

    # --- Numbers -----------------------------------------------------------------

    # Every tab's count, in one grouped query. Grouping by the state columns
    # (status, awaiting, assignee) and adding up in Ruby costs one round
    # trip; six `.count` calls cost six.
    def counts
      rows = Ticket.where(desk: desk).group(:status, :awaiting, :assignee_type, :assignee_id).count

      counts = TABS.index_with(0)
      rows.each do |(status, awaiting, assignee_type, assignee_id), count|
        assigned_to_me = agent_key == [ assignee_type, assignee_id.to_s ]

        case status
        when "open"
          counts[:open] += count
          counts[:mine] += count if assigned_to_me
          counts[:unassigned] += count if assignee_id.nil?
          counts[:awaiting] += count if awaiting == "agent"
        when "snoozed" then counts[:snoozed] += count
        when "closed" then counts[:closed] += count
        end
      end
      counts
    end

    # The nav badge: open tickets this agent should feel responsible for —
    # theirs, plus everything nobody has picked up. Cached briefly per agent.
    def badge
      return badge_count unless defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache

      Rails.cache.fetch(badge_cache_key, expires_in: BADGE_TTL) { badge_count }
    end

    # The ticket to open now: the most urgent among this agent's own and
    # the unclaimed ones.
    def next
      mine_or_unassigned.most_urgent_first.first
    end

    # [[:awaiting, "Pendientes", 4], …] — i18n labels, in display order,
    # ready to render.
    def tabs
      numbers = counts
      TABS.map { |tab| [ tab, I18n.t("support_desk.queue.tabs.#{tab}"), numbers[tab] ] }
    end

    # The relation behind a tab name, so a console can route `params[:tab]`
    # without a case statement.
    def scope(tab)
      tab = (tab.presence || :awaiting).to_sym
      raise ArgumentError, "unknown queue tab #{tab.inspect} (known: #{TABS.join(", ")})" unless TABS.include?(tab)

      public_send(tab)
    end

    def inspect
      "#<SupportDesk::Queue desk=#{desk.key} agent=#{agent.class}##{agent.id}>"
    end

    private

    def mine_or_unassigned
      all.open.where(
        Ticket.arel_table[:assignee_id].eq(nil).or(
          Ticket.arel_table[:assignee_type].eq(agent.class.polymorphic_name)
                .and(Ticket.arel_table[:assignee_id].eq(agent.id))
        )
      )
    end

    def badge_count = mine_or_unassigned.count

    def agent_key
      @agent_key ||= [ agent.class.polymorphic_name, agent.id.to_s ]
    end

    def badge_cache_key
      [ "support_desk", "queue", desk.key, "badge", SupportDesk.actor_key(agent) ]
    end
  end
end
