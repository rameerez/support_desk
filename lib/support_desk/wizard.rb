# frozen_string_literal: true

module SupportDesk
  # "What do you need help with?" as a plain object.
  #
  # The wizard is the step machine behind the requester-facing screens, and
  # it is deliberately NOT a controller: a host that ejects the views, a
  # native app, or a JSON API can all drive the same three steps.
  #
  #   wizard = SupportDesk::Wizard.new(alice, params)
  #   wizard.step       # :topic | :subject | :compose
  #   wizard.choices    # the topics to offer, or the records to pick from
  #   wizard.open!("My order never arrived")
  #
  # The three steps:
  #
  #   1. **Pick a topic.** One level at a time; a branch shows its children,
  #      a leaf ends the step. Deep-linking a path skips ahead.
  #   2. **Pick a thing** — only when the leaf attaches something. Candidates
  #      come from the topic or from the class's own picker, and the ones
  #      the requester already has an open case about are marked, not hidden.
  #   3. **Write.** The context card, the prefill, and the composer.
  #
  # Subjects arrive as SIGNED GlobalIDs and are re-checked against
  # `supportable_by?` anyway: a wizard that trusted a raw id would let
  # anybody open a ticket about anybody's order.
  class Wizard
    # What a subject token is signed for, so a token minted for one purpose
    # can't be replayed at another.
    SUBJECT_PURPOSE = :support_subject
    SUBJECT_TOKEN_TTL = 1.hour

    STEPS = %i[topic subject compose].freeze

    attr_reader :requester, :params

    # Sign a record for a door or a picker link.
    def self.sign_subject(record)
      record.to_sgid(expires_in: SUBJECT_TOKEN_TTL, for: SUBJECT_PURPOSE).to_s
    end

    # Resolve a signed subject token, or nil when it's missing, expired,
    # forged, or points at something that has since been deleted.
    def self.find_signed_subject(token)
      return nil if token.blank?

      GlobalID::Locator.locate_signed(token.to_s, for: SUBJECT_PURPOSE)
    rescue StandardError
      nil
    end

    # +params+ accepts `topic:` (a path), `subject:` (a signed GlobalID) and
    # `about:` (a record, for hosts driving the wizard in Ruby).
    def initialize(requester, params = {}, desk: nil)
      @requester = requester
      @params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h.symbolize_keys : params.symbolize_keys
      @desk = desk
    end

    # The desk this requester writes to.
    def desk
      @desk ||= SupportDesk.desk(requester.class.try(:support_desk_key) || :default)
    end

    # That desk's topic tree.
    def tree = desk.config.topics

    # Which step the requester is on, given what they've chosen so far.
    def step
      return :topic if topic.nil? || topic.branch?
      return :subject if needs_subject?

      :compose
    end

    # Which step this is, for a view that would rather ask than compare.
    def topic_step? = step == :topic
    # Picking the thing it's about.
    def subject_step? = step == :subject
    # Writing the message.
    def compose_step? = step == :compose

    # The chosen topic, resolved from the `topic:` param or from the chosen
    # subject. nil until they've picked one.
    def topic
      return @topic if defined?(@topic)

      @topic = resolve_topic
    end

    # The chosen subject, if any — always re-checked against
    # `supportable_by?`, never trusted from the params.
    def subject
      return @subject if defined?(@subject)

      @subject = resolve_subject
    end

    # What to render on this step: the topics to offer, or the records to
    # pick from. Always a collection, never nil.
    def choices
      case step
      when :topic then tree.visible_for(requester, under: topic&.path)
      when :subject then candidates
      else []
      end
    end

    # The records the picker would offer, resolved once per wizard: the
    # step machine asks whether there are any, and then the view asks for
    # them, and a `candidates:` proc that runs a query shouldn't run it twice.
    def candidates
      @candidates ||= Array(topic&.candidates_for(requester))
    end

    # The state this step carries into the next request — what the composer
    # round-trips as hidden fields, so a POST lands on exactly the step the
    # GET rendered.
    def state_params
      { topic: topic&.path, subject: subject_token, no_subject: (1 if declined_subject?) }.compact
    end

    # The prompt above the choices.
    def ask
      case step
      when :topic then topic&.ask || I18n.t("support_desk.wizard.ask_topic")
      when :subject then topic.ask || I18n.t("support_desk.wizard.ask_subject")
      end
    end

    # Whether the picker should offer "none of these".
    def subject_optional?
      subject_step? && topic.subject_mode == :optional
    end

    # Text to drop into the composer, from the topic's `prefill:`.
    def prefill
      topic&.prefill(subject)
    end

    # The composer's placeholder for this topic.
    def placeholder
      topic&.placeholder || I18n.t("support_desk.wizard.placeholder")
    end

    # The promise shown next to the composer ("we usually reply in under a
    # day"), built from `config.reply_within` — one setting, one truth: the
    # same number the SLA breaches on.
    def promise
      return nil if promise_within.nil?

      I18n.t("support_desk.thread.promise", time: self.class.humanize_duration(promise_within))
    end

    # The promise as a Duration, for hosts that want to phrase it themselves.
    def promise_within = desk.config.reply_within

    # "1 day", "4 horas" — through ActionView's date helper so it speaks the
    # requester's language, falling back to Duration#inspect in the (rare)
    # app that has no ActionView.
    def self.humanize_duration(duration)
      return duration.inspect unless defined?(ActionView::Helpers::DateHelper)

      @duration_words ||= Object.new.extend(ActionView::Helpers::DateHelper)
      words = @duration_words.distance_of_time_in_words(duration.to_i).to_s
      # An app whose locale has no date translations (no rails-i18n) would
      # otherwise show "Translation missing" to a customer.
      words.start_with?("Translation missing") ? duration.inspect : words
    end

    # The open case this would land in, when the requester already has one
    # about this thing — so the wizard can say "you already have a
    # conversation open" and link to it instead of opening a second.
    def existing_ticket
      return nil if topic.nil? || topic.branch?

      key = Ticket.cardinality_key_for(requester: requester, subject: subject, topic: topic)
      return nil if key.start_with?("free:")

      Ticket.not_closed.find_by(requester: requester, desk: desk, cardinality_key: key)
    end

    # Which records in +choices+ the requester already has an open case
    # about, so the picker can mark them. One query per wizard, not one per
    # row.
    def open_tickets_by_subject
      return @open_tickets_by_subject if defined?(@open_tickets_by_subject)

      @open_tickets_by_subject =
        if subject_step?
          Ticket.not_closed.where(requester: requester, desk: desk)
                .where.not(subject_id: nil)
                .index_by { |ticket| [ ticket.subject_type, ticket.subject_id.to_s ] }
        else
          {}
        end
    end

    # The open case this requester already has about +record+, or nil — what
    # the picker marks with "Ya tienes una conversación abierta" and links to
    # instead of offering as a choice.
    def open_ticket_about(record)
      return nil if record.nil?

      open_tickets_by_subject[[ record.class.polymorphic_name, record.id.to_s ]]
    end

    # True when the params named a subject that didn't resolve: a forged or
    # expired token, a record that has since been deleted, one that isn't
    # supportable, or somebody else's. Callers turn this into a 404 — "not
    # yours" and "not there" must look the same from outside.
    def subject_rejected?
      subject_named? && subject.nil?
    end

    # The params that take the requester one step back, or nil when this is
    # the first screen. An empty Hash means the top of the topic tree, so
    # `new_ticket_path(wizard.back)` is always the right link — the wizard
    # never leans on `history.back()`, because every step is a real URL.
    def back
      case step
      when :topic then topic && level_above(topic)
      when :subject then level_above(topic)
      when :compose then picker_step? ? { topic: topic.path } : level_above(topic)
      end
    end

    # Submit. Raises SupportDesk::InvalidTransition when the wizard isn't
    # finished — a host that renders its own form can't half-submit one.
    def open!(message, files: [])
      unless compose_step?
        raise InvalidTransition, "the wizard is still on the #{step} step — pick one before submitting"
      end

      requester.ask_support!(message, about: subject, topic: topic.path, files: files)
    end

    # A signed token for the currently chosen subject, to round-trip through
    # the next form.
    def subject_token
      subject && self.class.sign_subject(subject)
    end

    # Where the requester has got to, in one line.
    def inspect
      "#<SupportDesk::Wizard step=#{step} topic=#{topic&.path.inspect} subject=#{subject.inspect}>"
    end

    private

    def needs_subject?
      return false if topic.nil? || topic.free_form?
      return false if subject
      return false if topic.about.empty?

      return false if topic.subject_mode == :none
      # "None of these" is only on offer when the topic said it was optional.
      return false if declined_subject?
      # Nothing to pick from and nothing insisting we pick: asking "which
      # one?" above an empty list is a dead end, so skip straight to writing.
      return false if candidates.empty? && topic.subject_mode != :required

      true
    end

    # Whether they answered "ninguno de estos" — only an answer at all when
    # the topic offered it.
    def declined_subject?
      params.key?(:no_subject) && topic&.subject_mode == :optional
    end

    # True when the params tried to name a subject at all — used to tell
    # "they haven't picked one yet" apart from "the one they named is not
    # theirs".
    def subject_named?
      params[:about].present? || params[:subject].present?
    end

    # Whether this topic has a picker that would actually RENDER — which is
    # what decides where "back" from the composer goes. A picker skipped for
    # having nothing in it must not be the place back leads to, or back
    # forwards straight to where it came from.
    def picker_step?
      return false if topic.nil? || topic.free_form? || topic.about.empty?
      return true if topic.subject_mode == :required

      candidates.any?
    end

    # The params for the level of the tree +node+ was chosen from: its
    # parent branch, or the top level ({}).
    def level_above(node)
      node&.parent ? { topic: node.parent.path } : {}
    end

    def resolve_topic
      path = params[:topic].presence
      chosen = path ? nil : resolve_subject
      node = if path
               tree.find(path.to_s)
      elsif chosen
               tree.find(chosen.support_topic.to_s)
      end

      # A deep link is a list of one: a topic this requester would never be
      # offered is not one they may walk into by typing its path — nor by
      # pointing at a record whose own `support_topic` is hidden from them,
      # which is the same bypass wearing a different hat.
      return node&.visible_for?(requester) ? node : nil if path || chosen

      # Nothing on offer at all: every branch behind an `only:`, or a desk
      # with no tree. The wizard must not open on a question with no
      # answers, so it starts at the composer under the DECLARED way out
      # (`other`, or `free_form: true`) — and only when that leaf is one
      # this requester may use, because `Ticket.open!` refuses a hidden
      # topic and a composer that 404s on submit is worse than a refusal.
      #
      # nil when the tree declares no exit, or hides the one it declares:
      # the requester stays on the topic step with nothing to choose, and
      # the screen says so.
      return nil unless tree.visible_for(requester).empty?

      exit_leaf = tree.free_form_leaf
      exit_leaf if exit_leaf&.visible_for?(requester)
    end

    def resolve_subject
      record = subject_from_params
      return nil if record.nil?
      return nil unless record.respond_to?(:supportable?) && record.supportable?
      return nil unless record.supportable_by?(requester)

      record
    end

    # `about:` is the one param a door, a deep link and a host driving the
    # wizard in Ruby all use, so it accepts BOTH: a signed GlobalID off the
    # query string, or the record itself. `subject:` is the same token under
    # the name the wizard's own forms round-trip it as.
    def subject_from_params
      given = params[:about]
      return given unless given.nil? || given.is_a?(String)

      self.class.find_signed_subject(given.presence || params[:subject])
    end
  end
end
