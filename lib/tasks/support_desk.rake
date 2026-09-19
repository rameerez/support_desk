# frozen_string_literal: true

namespace :support_desk do
  desc "Point every case with no provenance at its requester (the 0.1 → 0.2 catch-up)"
  task backfill_opened_by: :environment do
    # The same UPDATE the 0.2.0 migration runs, for the handover window: a
    # 0.1 process still serving traffic writes NULL provenance after the
    # migration's own backfill, so the catch-up is run once more when those
    # processes are gone.
    #
    # Idempotent, and safe to run at any time, for one reason: 0.2 opens
    # every case as a record (automation openers are refused — see
    # docs/12-open-questions.md Q17), so a NULL `opened_by` can only be a row
    # 0.1 wrote. The day automation lands, NULL becomes legitimate provenance
    # and this task stops being safe — that is part of the work Q17 names.
    relation = SupportDesk::Ticket.where(opened_by_id: nil)
    pending = relation.count

    if pending.zero?
      puts "[support_desk] every case already says who opened it."
      next
    end

    updated = relation.update_all("opened_by_type = requester_type, opened_by_id = requester_id")
    puts "[support_desk] #{updated} case(s) now point at their requester."
  end
end

namespace :support_desk do
  desc "Hand over every case an assistant has sat on without answering (run every minute)"
  task release_silent_assistants: :environment do
    # The net under a dead harness: a queue worker that stopped, a provider
    # that is down, a job that spent its last retry. Each case it finds has
    # its seat released AND a person asked for — a case that waited that
    # long deserves one, whatever the assistant would have said.
    moved = SupportDesk.release_silent_assistants!

    puts "[support_desk] #{moved} case(s) handed to a person."
  end

  desc "Re-emit the turn for cases nobody answered (OLDER_THAN=60 seconds; run every 5 minutes)"
  task redispatch_assistant_turns: :environment do
    # At-least-once, and that is safe: the turn is consumed by the first
    # action, so a duplicate one is a StaleTurn and writes nothing.
    older_than = (ENV["OLDER_THAN"] || 60).to_i.seconds
    emitted = SupportDesk.redispatch_assistant_turns!(older_than: older_than)

    puts "[support_desk] #{emitted} turn(s) re-emitted (idle for more than #{older_than.inspect})."
  end

  desc "What the assistants are doing right now (read-only)"
  task assistant_status: :environment do
    if SupportDesk.config.assistants.empty?
      puts "[support_desk] no assistant is configured."
      next
    end

    SupportDesk.config.assistants.each_key do |key|
      assistant = SupportDesk.assistant(key)
      held = assistant.held_tickets.count
      idle_window = assistant.responds_within
      idle = if idle_window
        SupportDesk::Ticket.open.assistant_idle_since(idle_window.ago).count
      end

      puts "[support_desk] #{key} (#{assistant.active? ? "active" : "inactive"}, #{assistant.autonomy}): " \
           "#{held} case(s) held, #{idle || "—"} idle turn(s)"
    end

    puts "[support_desk] #{SupportDesk::Ticket.open.needs_human.count} case(s) need a person, " \
         "#{SupportDesk::Draft.pending.count} proposal(s) waiting to be reviewed."
  end
end
