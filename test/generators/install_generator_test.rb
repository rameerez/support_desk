# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/support_desk/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests SupportDesk::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "creates the migration and the initializer" do
    run_generator

    assert_migration "db/migrate/create_support_desk_tables.rb" do |migration|
      assert_match(/class CreateSupportDeskTables < ActiveRecord::Migration\[\d+\.\d+\]/, migration)

      %w[support_desk_desks support_desk_tickets support_desk_assignments support_desk_events].each do |table|
        assert_match(/create_table :#{table}, id: primary_key_type/, migration)
      end

      # The adaptive machinery the whole gem ecosystem standardizes on.
      assert_match(/primary_key_type, foreign_key_type = primary_and_foreign_key_types/, migration)
      assert_match(/config\.options\[config\.orm\]\[:primary_key_type\]/, migration)
      assert_match(/return :jsonb if connection\.adapter_name\.downcase\.include\?\("postgresql"\)/, migration)
      assert_match(/return nil if connection\.adapter_name\.downcase\.include\?\("mysql"\)/, migration)

      # Polymorphic references carry the adaptive FK type.
      assert_match(/t\.references :requester, polymorphic: true, null: false, type: foreign_key_type/, migration)
      assert_match(/t\.references :agent, polymorphic: true, null: false, type: foreign_key_type/, migration)

      # The cardinality guarantee, and the PostgreSQL-only partial indexes.
      assert_match(/t\.string :cardinality_key, null: false/, migration)
      assert_match(/if postgres\?/, migration)
      assert_match(/unique: true, where: "status <> 'closed'"/, migration)
      assert_match(/unique: true, where: "released_at IS NULL"/, migration)

      # Events are append-only: created_at, and no updated_at.
      assert_match(/t\.datetime :created_at, null: false/, migration)
      assert_no_match(/create_table :support_desk_events.*t\.timestamps/m, migration)
    end

    assert_file "config/initializers/support_desk.rb" do |initializer|
      assert_match(/SupportDesk\.configure do \|config\|/, initializer)
      assert_match(/config\.requester_class = "User"/, initializer)
      assert_match(/config\.agents \{ User\.where\(admin: true\) \}/, initializer)
      assert_match(/config\.topics do/, initializer)
      assert_match(/config\.reply_policy/, initializer)
      assert_match(/config\.closed_tickets/, initializer)
      assert_match(/config\.reply_within/, initializer)
      assert_match(/config\.desk :billing do \|desk\|/, initializer)
      assert_match(/config\.on\(:ticket_opened\)/, initializer)
    end
  end

  test "the initializer documents every setting the gem has" do
    run_generator

    assert_file "config/initializers/support_desk.rb" do |initializer|
      SupportDesk::Configuration::DESK_SETTINGS.each do |setting|
        assert_match(/config\.#{setting}/, initializer, "#{setting} is undocumented in the initializer")
      end
    end
  end

  test "running twice doesn't duplicate the migration" do
    run_generator
    run_generator

    migrations = Dir[File.join(destination_root, "db/migrate/*_create_support_desk_tables.rb")]

    assert_equal 1, migrations.size
  end

  test "the dummy app migrates a copy of chats' template too" do
    # Locate chats through its loaded gem, never a path relative to this
    # checkout: the suite also runs from git worktrees, where "../chats" is
    # a directory that does not exist.
    template = File.read(Chats::Engine.root.join(
      "lib/generators/chats/templates/create_chats_tables.rb.erb"
    ))
    copy = File.read(File.expand_path("../dummy/db/migrate/20260101000001_create_chats_tables.rb", __dir__))
    body = ->(source) { source[/def change.*/m] }

    # The author columns (chats 0.2 S3) are what `ticket.reply!` signs with.
    assert_match(/t\.references :author, polymorphic: true/, copy)
    assert_equal body.call(template), body.call(copy),
                 "test/dummy's chats migration has drifted from chats' install template — re-copy it"
  end

  test "the dummy app migrates a copy of the template, so they can't drift" do
    template = File.read(File.expand_path(
      "../../lib/generators/support_desk/templates/create_support_desk_tables.rb.erb", __dir__
    ))
    copy = File.read(File.expand_path(
      "../dummy/db/migrate/20260101000002_create_support_desk_tables.rb", __dir__
    ))

    body = ->(source) { source[/def change.*/m] }

    assert_equal body.call(template), body.call(copy),
                 "test/dummy's migration has drifted from the install template"
  end
end
