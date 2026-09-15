# frozen_string_literal: true

require "test_helper"

module SupportDesk
  class DeskTest < ActiveSupport::TestCase
    test "for finds or creates by key, and never inserts first" do
      desk = Desk.for(:default)

      assert_equal "default", desk.key
      assert_equal desk, Desk.for("default")
      assert_equal 1, Desk.where(key: "default").count
    end

    test "name comes from configuration, then settings, then the key" do
      desk = SupportDesk.desk

      assert_equal "Soporte", desk.name

      SupportDesk.config.name = nil
      desk.update!(settings: { "name" => "Mesa de ayuda" })

      assert_equal "Mesa de ayuda", Desk.for(:default).name
    end

    test "display_name is what chats renders as the counterpart" do
      assert_equal "Soporte", Chats.display_name_for(SupportDesk.desk)
    end

    test "avatar resolves a string or a callable" do
      SupportDesk.config.avatar = "support.png"

      assert_equal "support.png", SupportDesk.desk.avatar

      SupportDesk.config.avatar = ->(desk) { "#{desk.key}.png" }

      assert_equal "default.png", SupportDesk.desk.avatar
    end

    test "the desk is a headless chats messager" do
      desk = SupportDesk.desk

      assert_kind_of Chats::Messager, desk
      assert_not desk.class.chat_notifications?
      assert_not desk.class.chat_blockable?
      assert_equal :grouped, desk.class.chat_inbox_mode
      assert_predicate desk.class, :chat_grouped_inbox?
      assert_equal "/messages/support", desk.class.chat_group_path.call(create_user)
    end

    test "agents resolves the configured pool" do
      admin = create_user(admin: true)
      create_user(admin: false)

      assert_equal [ admin ], SupportDesk.desk.agents.to_a
      assert_equal [ admin ], SupportDesk.desk.on_duty_agents
    end

    test "on_duty_agents leaves out whoever says they are off duty" do
      on_duty = create_agent
      off_duty = create_agent
      off_duty.define_singleton_method(:on_duty?) { false }
      SupportDesk.config.agents { [ on_duty, off_duty ] }

      assert_equal [ on_duty, off_duty ], SupportDesk.desk.agents
      assert_equal [ on_duty ], SupportDesk.desk.on_duty_agents
    end

    test "agent? asks the record, not its class name" do
      assert SupportDesk.desk.agent?(create_agent)
      assert_not SupportDesk.desk.agent?(create_user(admin: false))
      assert_not SupportDesk.desk.agent?(nil)
    end

    test "a desk with tickets can't be destroyed" do
      ticket = ticket_for(create_user)

      assert_not ticket.desk.destroy
      assert_predicate ticket.desk.errors[:base], :any?
    end
  end
end
