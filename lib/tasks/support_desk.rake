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
