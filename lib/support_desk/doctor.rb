# frozen_string_literal: true

module SupportDesk
  # Everything that can only be checked against a running app: the
  # configuration the initializer wrote, the chats seams the gem is built
  # on, and the invariants the data is supposed to keep.
  #
  #   SupportDesk.doctor.print      # in a console
  #   exit 1 unless SupportDesk.doctor.ok?   # in CI
  #
  # Checks never raise: a doctor that blows up is a doctor nobody runs.
  class Doctor
    # One finding. :ok, :warn (worth fixing, nothing is broken) or :fail
    # (support is not working right now).
    Check = Struct.new(:name, :status, :message, keyword_init: true) do
      def ok? = status == :ok
      # Worth fixing, and actually broken.
      def warn? = status == :warn
      def fail? = status == :fail

      # "✓ name message" — one finding, printable.
      def to_s
        icon = { ok: "✓", warn: "!", fail: "✗" }.fetch(status)
        [ icon, name, message ].compact.join(" ")
      end
    end

    # What `SupportDesk.doctor` hands back.
    class Report
      attr_reader :checks

      # A report over the checks that were run.
      def initialize(checks)
        @checks = checks
      end

      # True when nothing failed. Warnings don't fail a build.
      def ok? = failures.empty?

      # The checks worth acting on: failures break support, warnings don't.
      def failures = checks.select(&:fail?)
      def warnings = checks.select(&:warn?)

      # Every check, one per line, with the verdict last.
      def to_s
        lines = checks.map(&:to_s)
        lines << (ok? ? "support_desk is healthy (#{warnings.size} warning(s))" : "#{failures.size} check(s) failed")
        lines.join("\n")
      end

      # Print the report and return whether it passed — the one line to
      # put in a CI step.
      def print(io = $stdout)
        io.puts(to_s)
        ok?
      end

      # The verdict, in one line.
      def inspect = "#<SupportDesk::Doctor::Report #{ok? ? "ok" : "#{failures.size} failed"}>"
    end

    # Run every check and hand back the report.
    def self.run = new.run

    # Run every check and hand back the report.
    def run
      checks = []
      checks.concat(configuration_checks)
      checks.concat(seam_checks)
      checks.concat(invariant_checks)
      Report.new(checks)
    end

    private

    def configuration_checks
      checks = []

      checks << check("requester_class") do
        klass = SupportDesk.config.requester_class.safe_constantize
        next fail_with("#{SupportDesk.config.requester_class} doesn't exist") unless klass
        unless klass.respond_to?(:support_desk_requester_options)
          next fail_with("#{klass} is missing `has_support_tickets`")
        end
        next fail_with("#{klass} is missing `acts_as_messager` (chats)") unless klass.include?(Chats::Messager)

        ok_with("#{klass} asks for support")
      end

      checks << check("agents") do
        pool = SupportDesk.config.default_desk.agent_pool
        next warn_with("no agent pool configured — set `config.agents { User.admin }`") if pool.nil?

        ok_with("#{pool.respond_to?(:count) ? pool.count : pool.size} agent(s)")
      end

      SupportDesk.config.desks.each_value do |desk|
        checks << check("topics (#{desk.key})") do
          tree = desk.topics
          next warn_with("no topics configured — every ticket lands on the free-form leaf") if tree.empty?
          next warn_with("no free-form topic: add `other` to the topics block") unless tree.free_form?

          ok_with("#{tree.count} topic(s), #{tree.leaves.size} leaf/leaves")
        end

        checks << check("supportables (#{desk.key})") do
          missing = desk.topics.about_class_names.reject do |name|
            klass = name.safe_constantize
            klass.respond_to?(:supportable?) && klass.supportable?
          end
          next fail_with("not supportable: #{missing.join(", ")}") if missing.any?

          ok_with("every about: class is supportable")
        end
      end

      checks << check("engine mount") do
        path = SupportDesk.root_path
        next warn_with("SupportDesk::Engine isn't mounted — requesters have nowhere to write") if path.nil?

        ok_with("mounted at #{path}")
      end

      checks << check("parent controllers") do
        missing = [ SupportDesk.config.parent_controller, SupportDesk.config.console_parent_controller ].reject do |name|
          name.safe_constantize
        end
        next fail_with("#{missing.join(", ")} doesn't exist") if missing.any?

        ok_with("resolved")
      end

      checks
    end

    # The chats seams this gem is built on. A host on the wrong chats
    # version should hear it from `doctor`, not from a NoMethodError in
    # production.
    def seam_checks
      [
        check("chats subscribers") do
          next fail_with("this chats doesn't expose `Chats.on` — support_desk needs chats ~> 0.2") unless
            Chats.respond_to?(:on)

          ok_with("Chats.on available")
        end,
        check("chats authorship") do
          next fail_with("chats_messages has no author column — run `rails g chats:upgrade`") unless
            Chats::Message.column_names.include?("author_id")

          ok_with("messages can be signed")
        end,
        check("desk messager") do
          next fail_with("SupportDesk::Desk isn't a chats messager") unless Desk.include?(Chats::Messager)

          ok_with("the desk converses")
        end
      ]
    end

    def invariant_checks
      return [ check("database") { warn_with("support_desk tables are missing — run rails db:migrate") } ] unless
        tables?

      [
        check("conversations") do
          orphans = Ticket.where(conversation_id: nil).count
          next fail_with("#{orphans} ticket(s) without a conversation") if orphans.positive?

          ok_with("every ticket has one")
        end,
        check("assignments") do
          duplicated = Assignment.open.group(:ticket_id).having("COUNT(*) > 1").count.size
          next fail_with("#{duplicated} ticket(s) with more than one open assignment") if duplicated.positive?

          ok_with("at most one open assignment per ticket")
        end,
        check("assignee pointers") do
          # A CLOSED ticket keeps its assignee with no open assignment row:
          # that is the record of who dealt with it, not a live seat.
          mismatched = Ticket.not_closed.assigned.where.not(
            id: Assignment.open.select(:ticket_id)
          ).count
          next fail_with("#{mismatched} ticket(s) whose assignee has no open assignment") if mismatched.positive?

          ok_with("assignee matches the open assignment")
        end,
        check("provenance") do
          next warn_with("no opened_by column — run `rails g support_desk:upgrade` and migrate") unless
            Ticket.column_names.include?("opened_by_id")

          half = Ticket.where(opened_by_type: nil).where.not(opened_by_id: nil)
                       .or(Ticket.where.not(opened_by_type: nil).where(opened_by_id: nil)).count
          next fail_with("#{half} ticket(s) with half an opened_by (a type and no id, or the reverse)") if
            half.positive?

          # NULL is not automation: nothing in this version writes it, so
          # every one of these is a row 0.1 opened, or one an old process
          # wrote during the upgrade window.
          legacy = Ticket.where(opened_by_id: nil).count
          next warn_with("#{legacy} case(s) don't say who opened them — run " \
                         "`rake support_desk:backfill_opened_by`") if legacy.positive?

          ok_with("every case says who opened it")
        end,
        check("awaiting") do
          # The NULL leg is not decoration: `last_agent_message_at >
          # last_requester_message_at` is NULL when the requester has never
          # written, so a case waiting on the desk that only the desk has
          # spoken in slips past a plain comparison.
          stale = Ticket.awaiting_reply.where(
            "last_agent_message_at > last_requester_message_at OR " \
            "(last_agent_message_at IS NOT NULL AND last_requester_message_at IS NULL)"
          ).count
          next fail_with("#{stale} ticket(s) waiting on the desk after the desk already answered") if stale.positive?

          ok_with("awaiting agrees with the transcript")
        end,
        check("references") do
          duplicated = Ticket.group(:reference).having("COUNT(*) > 1").count.size
          next fail_with("#{duplicated} duplicated reference(s)") if duplicated.positive?

          ok_with("references are unique")
        end
      ]
    end

    def tables?
      ActiveRecord::Base.connection.table_exists?(Ticket.table_name)
    rescue StandardError
      false
    end

    def check(name)
      status, message = yield
      Check.new(name: name, status: status, message: message)
    rescue StandardError => e
      Check.new(name: name, status: :fail, message: "#{e.class}: #{e.message}")
    end

    def ok_with(message) = [ :ok, message ]
    def warn_with(message) = [ :warn, message ]
    def fail_with(message) = [ :fail, message ]
  end
end
