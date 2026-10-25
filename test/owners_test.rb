# frozen_string_literal: true

require "test_helper"

# One process, a desk per customer. The owner is any record — here two
# Users stand in for two workspaces — and SupportDesk::Current.owner says
# whose desk a key means.
class OwnersTest < ActiveSupport::TestCase
  setup do
    @acme = create_user(name: "Acme")
    @globex = create_user(name: "Globex")
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
  end

  def as(owner, &block) = SupportDesk::Current.set(owner: owner, &block)

  # --- Resolution ------------------------------------------------------------------

  test "every owner has its own default desk, and no owner is the single-desk app" do
    ownerless = SupportDesk.desk
    acme = as(@acme) { SupportDesk.desk }
    globex = as(@globex) { SupportDesk.desk }

    assert_equal [ "default" ], [ acme, globex, ownerless ].map(&:key).uniq
    assert_equal 3, [ acme, globex, ownerless ].map(&:id).uniq.size
    assert_equal @acme, acme.owner
    assert_nil ownerless.owner
    assert_same ownerless, SupportDesk.desk, "the ownerless desk is still memoised for the process"
  end

  test "an owned desk is cached for the request, and the next request reads it again" do
    first = as(@acme) { SupportDesk.desk }

    assert_same first, as(@acme) { SupportDesk.desk }

    SupportDesk::Current.reset
    assert_not_same first, as(@acme) { SupportDesk.desk }
    assert_equal first, as(@acme) { SupportDesk.desk }
  end

  test "owner: names the owner explicitly, whatever Current says" do
    assert_equal @globex, as(@acme) { SupportDesk.desk(:default, owner: @globex) }.owner
  end

  test "an owner must be a saved record" do
    assert_raises(ArgumentError) { as(User.new) { SupportDesk.desk } }
  end

  test "a key is unique per owner, in the database" do
    skip_unless_partial_indexes
    as(@acme) { SupportDesk.desk }
    SupportDesk.desk

    assert_raises(ActiveRecord::RecordNotUnique) { SupportDesk::Desk.create!(key: "default", owner: @acme) }
    assert_raises(ActiveRecord::RecordNotUnique) { SupportDesk::Desk.create!(key: "default") }
  end

  test "an owner's desk is worked by that owner's assistant" do
    configure_assistant!(:rose)
    acme = as(@acme) { SupportDesk.desk }
    globex = as(@globex) { SupportDesk.desk }

    assert_equal @acme, acme.assistant.owner
    assert_equal @globex, globex.assistant.owner
    assert_not_equal acme.assistant, globex.assistant
    assert_equal [ acme ], acme.assistant.desks
  end

  test "one owner's assistant cannot act on another owner's case" do
    configure_assistant!(:rose, autonomy: :reply)
    ticket = as(@acme) { ticket_for(@alice, message: "Hola") }
    globex_rose = as(@globex) { SupportDesk.assistant(:rose) }

    error = assert_raises(SupportDesk::NotAnAssistant) do
      ticket.respond!("hola", by: globex_rose, turn: ticket.assistant_turn)
    end
    assert_match(/not desk default's assistant/, error.message)
  end

  # --- Cases and scopes ----------------------------------------------------------------

  test "a requester's case opens on the current owner's desk" do
    ticket = as(@acme) { ticket_for(@alice) }

    assert_equal @acme, ticket.desk.owner
  end

  test "for_desk, the SLA scopes and the console's desks read the current owner's rows only" do
    acme_case = as(@acme) { ticket_for(@alice) }
    globex_case = as(@globex) { ticket_for(@alice) }
    SupportDesk::Ticket.where(id: [ acme_case, globex_case ]).update_all(waiting_since: 2.days.ago)

    as(@acme) do
      assert_equal [ acme_case ], SupportDesk::Ticket.for_desk(:default).to_a
      assert_equal [ acme_case ], SupportDesk::Ticket.overdue.to_a
      assert_equal [ acme_case.desk ], SupportDesk.config.desks_visible_to(@lucia).to_a
    end
    assert_empty SupportDesk::Ticket.overdue.where(id: [ acme_case, globex_case ])
  end

  # --- Settings from rows ----------------------------------------------------------------

  test "desk_settings overlays the initializer with each owner's own settings" do
    SupportDesk.config.desk_settings = lambda do |desk|
      { name: "#{desk.owner.name} Help", reply_within: 2.hours } if desk.owner
    end

    acme = as(@acme) { SupportDesk.desk }

    assert_equal "Acme Help", acme.name
    assert_equal 2.hours, acme.config.reply_within
    assert_equal 4.hours, acme.config.at_risk_after, "what the row leaves out comes from the initializer"
    assert_equal "Soporte", SupportDesk.desk.name
  end

  test "each owner's promise decides its own overdue cases" do
    SupportDesk.config.desk_settings = ->(desk) { { reply_within: 1.hour } if desk.owner == @acme }
    acme_case = as(@acme) { ticket_for(@alice) }
    globex_case = as(@globex) { ticket_for(@alice) }
    SupportDesk::Ticket.where(id: [ acme_case, globex_case ]).update_all(waiting_since: 2.hours.ago)

    assert_equal [ acme_case ], as(@acme) { SupportDesk::Ticket.overdue.to_a }
    assert_empty as(@globex) { SupportDesk::Ticket.overdue.to_a }
  end

  test "an owner's topic tree comes from its row, and finds its topics" do
    SupportDesk.config.desk_settings = lambda do |desk|
      next unless desk.owner == @acme

      { topics: proc {
        topic :shipping
        other
      } }
    end

    acme = as(@acme) { SupportDesk.desk }

    assert_equal %w[shipping other], acme.config.topics.map(&:path)
    assert_equal "shipping", as(@acme) { SupportDesk.find_topic("shipping") }.path
    assert_kind_of SupportDesk::Topic::Unknown, SupportDesk.find_topic("shipping")
    assert_equal "shipping", as(@acme) { ticket_for(@alice, topic: :shipping) }.topic.path
  end

  test "a row that names something that is not a setting fails like a bad initializer" do
    SupportDesk.config.desk_settings = ->(_desk) { { reply_whenever: 1.hour } }

    error = assert_raises(SupportDesk::ConfigurationError) { as(@acme) { SupportDesk.desk }.config }
    assert_match(/reply_whenever/, error.message)

    SupportDesk.config.desk_settings = ->(_desk) { { reply_policy: :whoever } }
    SupportDesk::Current.reset
    assert_raises(SupportDesk::ConfigurationError) { as(@acme) { SupportDesk.desk }.config }
  end

  test "assistant_settings gives each owner's assistant her own level" do
    configure_assistant!(:rose, autonomy: :draft)
    SupportDesk.config.assistant_settings = ->(assistant) { { autonomy: :reply } if assistant.owner == @acme }

    assert_equal :reply, as(@acme) { SupportDesk.assistant(:rose) }.autonomy
    assert_equal :draft, as(@globex) { SupportDesk.assistant(:rose) }.autonomy
    assert_equal :signature, as(@acme) { SupportDesk.assistant(:rose) }.disclosure
  end

  test "the hooks validate on assignment" do
    assert_raises(SupportDesk::ConfigurationError) { SupportDesk.config.desk_settings = :nope }
    assert_raises(SupportDesk::ConfigurationError) { SupportDesk.config.assistant_settings = "nope" }
  end

  # --- Sweeps run for everybody --------------------------------------------------------

  test "the silence sweep hands back every owner's silent cases" do
    configure_assistant!(:rose, autonomy: :reply, responds_within: 1.minute)
    tickets = [ @acme, @globex ].map do |owner|
      as(owner) do
        ticket = ticket_for(@alice, message: "Hola")
        ticket.assign!(to: SupportDesk.assistant(:rose), by: @lucia)
        ticket
      end
    end
    SupportDesk::Ticket.where(id: tickets).update_all(waiting_since: 10.minutes.ago)

    assert_equal 2, SupportDesk.release_silent_assistants!
    assert tickets.all? { |ticket| ticket.reload.human_required? }
  end
end
