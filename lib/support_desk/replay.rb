# frozen_string_literal: true

module SupportDesk
  # Everything the desk wrote down, in an order a reader can checkpoint
  # without ever skipping a row. Reached through SupportDesk::Events.replay;
  # see there for the contract and the README for why it is shaped this way.
  #
  # Two tables are the durable record: `support_desk_events` (every
  # transition, plus the `assistant_turn` and `draft_proposed` signals) and
  # `support_desk_message_registrations` (every message folded into a case).
  # Both carry `xact_id`, the 64-bit id of the transaction that wrote the row
  # (`pg_current_xact_id()`), and `position`, drawn from ONE sequence, so
  # `(xact_id, position)` is a single order across both and `position` alone
  # identifies a row.
  class Replay # :nodoc:
    # The cursor a reader keeps between pages of one range, as JSON-friendly
    # strings: the range's fixed end, and the last row handled.
    RESUME_KEYS = %w[until xact_id position].freeze

    def initialize(horizon:, resume: nil, batch_size: 500)
      @horizon = Integer(horizon || 0)
      @resume = resume&.to_h&.transform_keys(&:to_s)
      @batch_size = Integer(batch_size)
      raise ArgumentError, "batch_size must be positive" unless @batch_size.positive?
    end

    # Yield every row of the range, oldest first, then return the range's
    # end — the next horizon. Nothing is returned for a range that did not
    # drain: a raise leaves the caller's checkpoint where it was.
    #
    # Uncached, always: the snapshot is the same SQL on every poll, and a
    # query cache — on in every request and job — would hand back the first
    # answer and pin the horizon for as long as the executor lives.
    def each_row(&block)
      ensure_supported!
      Event.uncached { read_range(&block) }
    end

    private

    def read_range
      upper, after = start

      loop do
        page = next_page(upper, after)
        break if page.empty?

        page.each do |row|
          after = [ row.xact_id, row.position ]
          yield row, { "until" => upper, "xact_id" => after[0], "position" => after[1] }
        end
      end

      upper
    end

    attr_reader :horizon, :resume, :batch_size

    # A resumed range keeps the end it was started with. Recomputing it
    # would move the goalposts mid-range — harmless for completeness, but
    # the sub-cursor would then describe a range nobody checkpointed.
    def start
      return [ snapshot_horizon, nil ] if resume.nil?

      missing = RESUME_KEYS - resume.keys
      raise ArgumentError, "resume: is missing #{missing.join(", ")} — pass back what replay yielded" if missing.any?

      [ Integer(resume["until"]), [ Integer(resume["xact_id"]), Integer(resume["position"]) ] ]
    end

    # The oldest transaction still running. Every transaction below it has
    # committed or aborted, so the rows below it are final: present now, or
    # never going to exist.
    def snapshot_horizon
      Event.connection.select_value("SELECT pg_snapshot_xmin(pg_current_snapshot())::text::bigint").to_i
    end

    # The next page across both tables. Each table gives its own first
    # `batch_size` rows past the cursor, and the merged first `batch_size`
    # are exactly the first rows of the merged order.
    def next_page(upper, after)
      sources.flat_map { |model| page_of(model, upper, after) }
             .sort_by { |row| [ row.xact_id, row.position ] }
             .first(batch_size)
    end

    def page_of(model, upper, after)
      table = model.quoted_table_name
      scope = model.where("#{table}.xact_id >= ? AND #{table}.xact_id < ?", horizon, upper)
      scope = scope.where("(#{table}.xact_id, #{table}.position) > (?, ?)", *after) if after
      scope.order(:xact_id, :position).limit(batch_size).to_a
    end

    def sources = [ Event, MessageRegistration ]

    def ensure_supported!
      unless Event.connection.adapter_name.match?(/\Apostg/i)
        raise ConfigurationError,
              "SupportDesk::Events.replay needs PostgreSQL 13 or later: it reads transaction ids " \
              "(pg_current_xact_id), which #{Event.connection.adapter_name} does not have."
      end
      return if sources.all? { |model| model.column_names.include?("xact_id") }

      raise ConfigurationError,
            "support_desk's replay columns are missing — run `rails g support_desk:upgrade` and " \
            "`rails db:migrate` (support_desk 0.6.0 adds position and xact_id)."
    end
  end
end
