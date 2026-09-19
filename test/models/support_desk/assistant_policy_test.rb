# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # §12.3 — the policy table. Ceilings, then floors, and the sentence that
  # names the rule which decided it.
  #
  # `because` is asserted everywhere on purpose: a level with no reason is a
  # refusal nobody can act on, and the console, the brief and the event
  # payload all print this sentence.
  class AssistantPolicyTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @rose = configure_assistant!(autonomy: :resolve)
      @ticket = ticket_for(@alice, message: "Hola")
    end

    # --- Ceilings ----------------------------------------------------------------

    test "autonomy alone decides when nothing else caps her" do
      AssistantPolicy::LEVELS.each do |level|
        with_assistant_config(autonomy: level) do
          policy = @ticket.assistant_policy

          assert_equal level, policy.level
          assert_equal "rose's autonomy is #{level}", policy.because
          assert_equal({ assistant: level }, policy.ceilings)
          assert_empty policy.floors
        end
      end
    end

    test "a topic cap lowers her, and never raises her" do
      { observe: :observe, draft: :draft, reply: :reply, resolve: :resolve }.each do |cap, _|
        with_topic_assistant_cap("other", cap) do
          with_assistant_config(autonomy: :draft) do
            expected = AssistantPolicy::RANK[cap] < AssistantPolicy::RANK[:draft] ? cap : :draft
            policy = @ticket.assistant_policy

            assert_equal expected, policy.level
          end
        end
      end
    end

    test "the deciding ceiling is the one named" do
      with_topic_assistant_cap("other", :draft) do
        with_assistant_config(autonomy: :resolve) do
          assert_assistant_policy @ticket, :draft, because: "topic other caps rose at draft"
        end
      end
    end

    test "the host's cap block caps her, and garbage from it is a configuration error" do
      with_assistant_config(autonomy: :resolve, cap: ->(_ticket) { :observe }) do
        assert_assistant_policy @ticket, :observe, because: "cap block caps rose at observe"
      end

      with_assistant_config(autonomy: :resolve, cap: ->(_ticket) { nil }) do
        # A block with no opinion changes nothing.
        assert_assistant_policy @ticket, :resolve
      end

      with_assistant_config(cap: ->(_ticket) { :maybe }) do
        error = assert_raises(ConfigurationError) { @ticket.assistant_policy }

        assert_match(/cap block must return one of/, error.message)
      end
    end

    test "the case's own cap survives everything but a hand-back" do
      @ticket.update!(assistant_cap: "draft")

      assert_assistant_policy @ticket, :draft, because: "this case caps rose at draft"
      assert_equal :resolve, @ticket.assistant_policy(@rose, hand_back: true).level
    end

    test "a pause floors her at :off, and says so" do
      @ticket.pause_assistant!(by: @lucia, reason: "delicado")

      assert_assistant_policy @ticket, :off, because: "rose is paused on this case"
      refute_predicate @ticket.assistant_policy, :may_observe?
      assert_predicate @ticket.assistant_policy(@rose, hand_back: true), :may_hold?
    end

    test "the lowest ceiling wins whichever one it is" do
      @ticket.update!(assistant_cap: "reply")
      with_topic_assistant_cap("other", :draft) do
        with_assistant_config(autonomy: :resolve, cap: ->(_ticket) { :reply }) do
          policy = @ticket.assistant_policy

          assert_equal :draft, policy.level
          assert_equal({ assistant: :resolve, topic: :draft, cap: :reply, case: :reply }, policy.ceilings)
          assert_match(/topic other/, policy.because)
        end
      end
    end

    # --- Floors ------------------------------------------------------------------

    test "an inactive assistant may do nothing at all" do
      @rose.deactivate!(by: @lucia)

      assert_assistant_policy @ticket, :off, because: "rose is inactive"
      assert_includes @ticket.assistant_policy.floors, :inactive
      # Not even a hand-back can seat somebody who is switched off.
      refute_predicate @ticket.assistant_policy(@rose, hand_back: true), :may_hold?
    end

    test "a closed case floors her at :observe" do
      @ticket.reply!("Ya está", by: @lucia)
      @ticket.close!(by: @lucia)

      assert_assistant_policy @ticket, :observe, because: "the case is closed"
      assert_includes @ticket.assistant_policy.floors, :closed
      assert_equal :observe, @ticket.assistant_policy(@rose, hand_back: true).level
    end

    test "a person having been asked for floors her at :observe" do
      @ticket.request_human!(by: @alice)

      assert_assistant_policy @ticket, :observe, because: "a person was requested (requester_request)"
      assert_includes @ticket.assistant_policy.floors, :human_required
      assert_equal :resolve, @ticket.assistant_policy(@rose, hand_back: true).level,
                   "a hand-back is exactly the decision to lift it"
    end

    test "a human holding the case floors her at :draft" do
      @ticket.assign!(to: @lucia, by: @lucia)

      assert_assistant_policy @ticket, :draft, because: "Lucía holds the case"
      assert_includes @ticket.assistant_policy.floors, :held_by_human
      assert_predicate @ticket.assistant_policy, :may_draft?
      refute_predicate @ticket.assistant_policy, :may_reply?
    end

    test "her own seat is not a floor" do
      @ticket.assign!(to: @rose, by: @lucia)

      assert_equal :resolve, @ticket.assistant_policy.level
      assert_empty @ticket.assistant_policy.floors
    end

    test "floors stack, and the last one to lower her is the one that explains it" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.request_human!(by: @alice)

      policy = @ticket.assistant_policy

      assert_equal :observe, policy.level
      assert_equal %i[human_required], policy.floors
      assert_match(/a person was requested/, policy.because)
    end

    # --- The null policy ---------------------------------------------------------

    test "no assistant on the desk is a Null policy that answers no to everything" do
      SupportDesk.reset!
      configure_support_desk!
      policy = @ticket.reload.assistant_policy

      assert_predicate policy, :null?
      assert_equal :off, policy.level
      assert_equal "no assistant on desk default", policy.because
      refute_predicate policy, :may_observe?
      assert_empty policy.allowed_verbs
    end

    test "somebody else's assistant is a Null policy too" do
      SupportDesk.configure do |config|
        config.assistant(:max) { |assistant| assistant.disclosure = :none }
        config.default_assistant = :rose
      end
      max = SupportDesk.assistant(:max)
      policy = @ticket.assistant_policy(max)

      assert_predicate policy, :null?
      assert_equal "max is not desk default's assistant", policy.because
    end

    # --- The verb table ----------------------------------------------------------

    test "every level unlocks exactly its own verbs" do
      {
        off: [],
        observe: %i[note escalate release],
        draft: %i[note escalate release draft],
        reply: %i[note escalate release draft reply take],
        resolve: %i[note escalate release draft reply take close]
      }.each do |level, verbs|
        with_assistant_config(autonomy: level) do
          policy = @ticket.assistant_policy

          assert_equal verbs, policy.allowed_verbs, "#{level} allows the wrong verbs"
          verbs.each { |verb| assert policy.may?(verb), "#{level} should allow #{verb}" }
          policy.forbidden_verbs.each { |verb| refute policy.may?(verb), "#{level} should refuse #{verb}" }
        end
      end
    end

    test "the predicates line up with the levels" do
      with_assistant_config(autonomy: :reply) do
        policy = @ticket.assistant_policy

        assert_predicate policy, :may_observe?
        assert_predicate policy, :may_draft?
        assert_predicate policy, :may_reply?
        assert_predicate policy, :may_hold?
        refute_predicate policy, :may_close?
        assert policy.at_least?(:draft)
        refute policy.at_least?(:resolve)
      end
    end

    # --- What gets written down --------------------------------------------------

    test "to_h is the whole decision, which is what a message and an event carry" do
      with_topic_assistant_cap("other", :draft) do
        @ticket.assign!(to: @lucia, by: @lucia)
        hash = @ticket.assistant_policy.to_h

        assert_equal "rose", hash[:assistant]
        assert_equal :draft, hash[:level]
        assert_equal %i[assistant topic cap case pause], hash[:ceilings].keys
        assert_equal :draft, hash[:ceilings][:topic]
        assert_nil hash[:ceilings][:pause]
        assert_equal [], hash[:floors], "a floor that changed nothing is not a floor"
        assert_match(/caps rose at draft/, hash[:because])
      end
    end

    test "to_s reads like the sentence it is" do
      with_assistant_config(autonomy: :draft) do
        assert_equal "draft — rose's autonomy is draft", @ticket.assistant_policy.to_s
      end
    end

    test "the policy asks the database nothing" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.reload.topic
      @ticket.assignee

      queries = count_queries { @ticket.assistant_policy }

      assert_empty queries, "the policy runs under a row lock: it reads columns, not tables"
    end
  end
end
