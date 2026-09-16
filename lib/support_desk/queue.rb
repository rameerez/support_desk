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

    # An agent's view of one desk. Prefer `Queue.for` or
    # `agent.support_queue`.
    def initialize(agent, desk:)
      @agent = agent
      @desk = desk
    end

    # --- Relations ---------------------------------------------------------------
    #
    # Every tab states its OWN order, and the base scope states none. An
    # order baked into the base would win and every later `.order` would be
    # a dead tiebreaker — which is how a queue quietly starts handing out
    # the newest ticket when it promised the most urgent one.

    # Every ticket on this desk, newest first — the unfiltered list.
    def all
      scoped.newest_first
    end

    # Open and held by this agent, most urgent first.
    def mine
      scoped.open.assigned_to(agent).most_urgent_first
    end

    # Open and held by nobody, most urgent first.
    def unassigned
      scoped.open.unassigned.most_urgent_first
    end

    # Open and waiting on the desk — the tab that means "work".
    def awaiting
      scoped.open.awaiting_reply.most_urgent_first
    end

    # Put aside until a date, the soonest to wake first (0.2).
    def snoozed = scoped.snoozed.order(:snoozed_until)

    # Every live case on this desk, held or not, most urgent first.
    def open = scoped.open.most_urgent_first

    # Done, most recently touched first.
    def closed = scoped.closed.recent_activity_first

    # --- Numbers -----------------------------------------------------------------

    # Every tab's count, in one grouped query. Grouping by the state columns
    # (status, awaiting, assignee) and adding up in Ruby costs one round
    # trip; six `.count` calls cost six.
    def counts
      rows = scoped.group(:status, :awaiting, :assignee_type, :assignee_id).count

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

    # Whose queue, on which desk.
    def inspect
      "#<SupportDesk::Queue desk=#{desk.key} agent=#{agent.class}##{agent.id}>"
    end

    private

    # The base scope: this desk's tickets, in no particular order, so the
    # caller's order is the one that counts.
    def scoped
      Ticket.where(desk: desk)
    end

    def mine_or_unassigned
      scoped.open.where(
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
