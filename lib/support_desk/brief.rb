# frozen_string_literal: true

module SupportDesk
  # Everything a machine needs to answer one case, as plain data:
  #
  #   brief = ticket.brief
  #   brief.to_h      # a Hash you can hand to JSON.generate
  #   brief.to_text   # the same facts as sectioned plain text
  #   brief.policy    # what she may do here, and why
  #
  # It is the ONE thing a harness reads. Not chats' tables, not the console's
  # partials, not the ticket's columns: a brief is versioned
  # (`schema_version`), complete, and the same shape whatever the host looks
  # like — so a prompt written against it keeps working when the gem grows a
  # column.
  #
  # == Facts, never instructions
  #
  # There is not one imperative sentence in here, and there never will be.
  # What the assistant should DO with a case is the host's prompt, the
  # host's model and the host's problem; what the case IS is ours. A gem
  # that shipped "be polite and concise" inside a brief would be writing
  # somebody else's product copy in a place they cannot edit.
  #
  # The one thing the brief does state about behaviour is `may` / `may_not`,
  # and that is not advice either — it is the authorization, straight from
  # `AssistantPolicy`, so a harness never has to re-derive the rules it is
  # working under (§4.4).
  #
  # == This leaves your building
  #
  # Assume every field here reaches a third party the moment a harness calls
  # a model with it. Two fields are entirely yours to fill and therefore
  # yours to audit:
  #
  # * `case[:subject][:context]` — `Supportable#support_context`
  # * `requester[:context]` — `Requester#support_context`
  #
  # And `include_internal: true` adds the desk's private reasoning — notes
  # agents left for each other, proposals a human rejected and why. It is
  # off by default and it is opt-in per call for that reason.
  class Brief
    # The shape's version. Bumped when a key changes meaning or leaves;
    # a new key is not a bump, because a reader that ignores it is right.
    SCHEMA_VERSION = 1

    attr_reader :ticket, :transcript

    # The brief for +ticket+. `transcript_limit:` keeps the last n turns,
    # which is what a context window can actually hold.
    def initialize(ticket, include_internal: false, transcript_limit: 50)
      @ticket = ticket
      @include_internal = include_internal
      @transcript = ticket.transcript(limit: transcript_limit)
    end

    # Whether the desk's private reasoning is in here.
    def include_internal? = !!@include_internal

    # What the assistant may do on this case, and why — the same object
    # every verb asks under the row lock.
    def policy = ticket.assistant_policy

    # The whole brief, as data.
    def to_h
      {
        schema_version: SCHEMA_VERSION,
        desk: desk_facts,
        assistant: assistant_facts,
        case: case_facts,
        requester: requester_facts,
        internal: (internal_facts if include_internal?),
        transcript: transcript.to_h
      }.compact
    end

    # The same facts, as sectioned plain text — for a prompt that is cheaper
    # to read than JSON, and for a log line a person has to skim at 3 a.m.
    def to_text
      sections = [
        section("DESK", desk_lines),
        section("ASSISTANT", assistant_lines),
        section("CASE", case_lines),
        section("REQUESTER", requester_lines),
        (section("INTERNAL", internal_lines) if include_internal?),
        section("TRANSCRIPT", [ transcript.to_text ])
      ]
      sections.compact.join("\n\n")
    end

    def inspect
      "#<SupportDesk::Brief #{ticket.reference} #{transcript.size} turn(s)" \
        "#{" +internal" if include_internal?}>"
    end

    private

    def desk
      ticket.desk
    end

    def assistant
      ticket.assistant
    end

    def desk_facts
      reply_within = ticket.desk_config.reply_within

      {
        key: desk&.key,
        name: desk&.name,
        reply_within: (SupportDesk.humanize_duration(reply_within) if reply_within)
      }
    end

    # nil, not an empty Hash, when no assistant works this desk: "there is
    # no assistant here" and "there is one who may do nothing" are different
    # facts, and a harness that confuses them answers from a case it has no
    # seat on.
    def assistant_facts
      return nil if assistant.nil?

      decision = policy
      {
        key: assistant.key,
        # Her own name, not the disclosed one: what the requester is shown
        # is `disclosure`, one line down, and a model told it is called
        # "Rose · asistente virtual" starts signing itself that way.
        name: assistant.name,
        disclosure: assistant.disclosure,
        level: decision.level,
        because: decision.because,
        may: decision.allowed_verbs,
        may_not: decision.forbidden_verbs,
        turns: { used: ticket.assistant_turns_count.to_i, max: assistant.max_turns }
      }
    end

    def case_facts
      {
        reference: ticket.reference,
        status: ticket.status,
        awaiting: ticket.awaiting,
        opened_at: ticket.opened_at,
        opened_via: ticket.opened_via,
        opened_by: ticket.opened_by_requester? ? "requester" : "support",
        reopened: ticket.reopened?,
        human_required: human_required_facts,
        paused: ticket.assistant_paused?,
        cap: ticket.assistant_cap,
        topic: { path: ticket.topic&.path, label: ticket.topic&.full_label },
        subject: subject_facts
      }
    end

    def human_required_facts
      return nil unless ticket.human_required?

      { at: ticket.human_required_at, reason: ticket.human_required_reason }
    end

    def subject_facts
      subject = ticket.subject
      return nil if subject.nil?

      {
        type: subject.class.name,
        label: subject.try(:support_label),
        status: subject.try(:support_status),
        # The host's own key/value pairs. See the class comment: this is
        # what leaves the building.
        context: subject.try(:support_context) || {}
      }
    end

    def requester_facts
      requester = ticket.requester

      {
        name: Chats.display_name_for(requester),
        since: requester.try(:created_at),
        open_cases: Ticket.not_closed.where(requester: requester).count,
        context: requester.try(:support_context) || {}
      }
    end

    # The desk talking to itself. Only ever built when the caller asked.
    def internal_facts
      {
        notes: ticket.notes.map do |event|
          { at: event.created_at, by: SupportDesk.actor_key(event.actor_or_system), body: event.note }
        end,
        drafts: ticket.drafts.chronological.map do |draft|
          {
            at: draft.created_at,
            status: draft.status,
            body: draft.body,
            confidence: draft.confidence,
            edited: draft.edited?,
            sent_body: draft.sent_body,
            rejection_reason: draft.rejection_reason
          }
        end
      }
    end

    # --- The text rendering -------------------------------------------------------

    def section(title, lines)
      body = Array(lines).compact.reject { |line| line.to_s.strip.empty? }
      return nil if body.empty?

      "== #{title}\n#{body.join("\n")}"
    end

    def pair(label, value)
      return nil if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      "#{label}: #{value}"
    end

    def desk_lines
      facts = desk_facts
      [ pair("Desk", facts[:name]), pair("Answers within", facts[:reply_within]) ]
    end

    def assistant_lines
      facts = assistant_facts
      return [ "No assistant works this desk." ] if facts.nil?

      [
        pair("Assistant", facts[:name]),
        pair("Disclosure", facts[:disclosure]),
        pair("Level", "#{facts[:level]} (#{facts[:because]})"),
        pair("May", facts[:may].join(", ")),
        pair("May not", facts[:may_not].join(", ")),
        pair("Turns", "#{facts[:turns][:used]}/#{facts[:turns][:max] || "unlimited"}")
      ]
    end

    def case_lines
      facts = case_facts
      subject = facts[:subject]

      [
        pair("Reference", facts[:reference]),
        pair("Status", "#{facts[:status]} · awaiting #{facts[:awaiting] || "nobody"}"),
        pair("Opened", "#{facts[:opened_at]&.utc&.strftime("%Y-%m-%d %H:%M")} by #{facts[:opened_by]} " \
                       "via #{facts[:opened_via]}"),
        (pair("Reopened", "yes") if facts[:reopened]),
        (pair("A person was asked for", "#{facts[:human_required][:reason]} " \
                                        "(#{facts[:human_required][:at]&.utc&.strftime("%Y-%m-%d %H:%M")})") if
          facts[:human_required]),
        (pair("Assistant paused", "yes") if facts[:paused]),
        pair("Case cap", facts[:cap]),
        pair("Topic", facts[:topic][:label] || facts[:topic][:path]),
        (pair("About", "#{subject[:label]}#{" · #{subject[:status]}" if subject[:status]}") if subject),
        *(subject ? subject[:context].map { |key, value| pair("  #{key}", value) } : [])
      ]
    end

    def requester_lines
      facts = requester_facts

      [
        pair("Name", facts[:name]),
        pair("Customer since", facts[:since]&.utc&.strftime("%Y-%m-%d")),
        pair("Open cases", facts[:open_cases]),
        *facts[:context].map { |key, value| pair("  #{key}", value) }
      ]
    end

    def internal_lines
      facts = internal_facts

      facts[:notes].map { |note| "Note (#{note[:at]&.utc&.strftime("%Y-%m-%d %H:%M")}): #{note[:body]}" } +
        facts[:drafts].map do |draft|
          reason = draft[:rejection_reason]
          "Proposal (#{draft[:status]}#{" · #{reason}" if reason.present?}): #{draft[:body]}"
        end
    end
  end
end
