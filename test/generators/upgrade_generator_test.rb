# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/support_desk/upgrade_generator"

# The upgrade generator copies ONE migration, and it is the same one a fresh
# install runs — so the tests that matter are not "does the file say
# add_reference" but "does it do the right thing to a database". Everything
# below the generator section EXECUTES the migrations against a throwaway
# database: a fresh install, an upgrade from a populated 0.1 schema, the
# rollback, and the upgrade again.
class UpgradeGeneratorTest < Rails::Generators::TestCase
  tests SupportDesk::Generators::UpgradeGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  # The migrations run on a SECOND connection, and a second connection only
  # sees what has been committed — a PostgreSQL scratch schema created inside
  # this suite's test transaction would be invisible to it. So: real commits
  # here, and the scratch database is thrown away in an ensure.
  self.use_transactional_tests = false

  # Its own connection, to its own database: the suite's schema is what every
  # other test reads, and an execution test has to be free to create tables
  # and drop columns.
  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  SCRATCH_SCHEMA = "support_desk_migration_scratch"
  INDEX_NAME = "index_support_desk_tickets_on_opened_by"

  # --- The generator -----------------------------------------------------------

  test "writes the additive opened_by migration once" do
    run_generator
    run_generator

    assert_equal 1, Dir[File.join(destination_root, "db/migrate/*_add_opened_by_to_support_desk_tickets.rb")].size

    assert_migration "db/migrate/add_opened_by_to_support_desk_tickets.rb" do |migration|
      assert_match(/class AddOpenedByToSupportDeskTickets < ActiveRecord::Migration\[\d+\.\d+\]/, migration)
      assert_match(/add_reference :support_desk_tickets, :opened_by, polymorphic: true/, migration)
      assert_match(/type: opened_by_id_type/, migration)
      assert_match(/name: INDEX_NAME/, migration)
      assert_match(/SET opened_by_type = requester_type/, migration)
      # Its own index and its own two columns — never the create migration's.
      assert_match(/def down/, migration)
      assert_match(/remove_column :support_desk_tickets, :opened_by_type/, migration)
      assert_no_match(/drop_table/, migration)
    end
  end

  test "the upgrade message names the deploy order and the catch-up task" do
    output = run_generator

    assert_match(/rails db:migrate/, output)
    assert_match(/support_desk:backfill_opened_by/, output)
    assert_match(/open_support_conversation_with!/, output)
  end

  test "the dummy app migrates a copy of the template, so they can't drift" do
    template = File.read(File.expand_path(
      "../../lib/generators/support_desk/templates/add_opened_by_to_support_desk_tickets.rb.erb", __dir__
    ))
    copy = File.read(File.expand_path(
      "../dummy/db/migrate/20260101000004_add_opened_by_to_support_desk_tickets.rb", __dir__
    ))
    body = ->(source) { source.split(/^class .*\n/, 2).last }

    assert_equal body.call(template), body.call(copy),
                 "test/dummy's opened_by migration has drifted from the upgrade template"
  end

  # --- The migration, executed --------------------------------------------------

  test "a fresh install creates the 0.1 tables and then adds provenance to them" do
    with_scratch_database do |connection|
      run_migration("CreateSupportDeskTables", connection)

      assert_not connection.column_exists?(:support_desk_tickets, :opened_by_id),
                 "the create migration must not own opened_by — one file does, and it is the additive one"

      run_migration("AddOpenedByToSupportDeskTickets", connection)

      assert connection.column_exists?(:support_desk_tickets, :opened_by_type)
      assert connection.column_exists?(:support_desk_tickets, :opened_by_id)
      assert connection.index_exists?(:support_desk_tickets, [ :opened_by_type, :opened_by_id ], name: INDEX_NAME)
      assert_equal sql_type(connection, "requester_id"), sql_type(connection, "opened_by_id")
    end
  end

  test "upgrading a populated 0.1 schema points every case at its requester" do
    with_scratch_database do |connection|
      run_migration("CreateSupportDeskTables", connection)
      desk_id = insert_desk(connection)
      insert_legacy_ticket(connection, desk_id: desk_id, requester_type: "User", requester_id: 7)
      insert_legacy_ticket(connection, desk_id: desk_id, requester_type: "Organization", requester_id: 42)

      run_migration("AddOpenedByToSupportDeskTickets", connection)

      assert_equal [ [ "User#7", "User#7" ], [ "Organization#42", "Organization#42" ] ], provenance(connection)
    end
  end

  test "the additive migration rolls back exactly what it added, and can be run again" do
    with_scratch_database do |connection|
      run_migration("CreateSupportDeskTables", connection)
      desk_id = insert_desk(connection)
      insert_legacy_ticket(connection, desk_id: desk_id, requester_type: "User", requester_id: 7)
      run_migration("AddOpenedByToSupportDeskTickets", connection)

      run_migration("AddOpenedByToSupportDeskTickets", connection, :down)

      assert_not connection.column_exists?(:support_desk_tickets, :opened_by_type)
      assert_not connection.column_exists?(:support_desk_tickets, :opened_by_id)
      assert_not connection.index_exists?(:support_desk_tickets, [ :opened_by_type, :opened_by_id ], name: INDEX_NAME)
      # The create migration's own indexes are none of its business.
      assert connection.index_exists?(:support_desk_tickets, :reference,
                                      name: "index_support_desk_tickets_on_reference")
      assert connection.index_exists?(:support_desk_tickets, [ :requester_type, :requester_id, :desk_id,
                                                               :cardinality_key ],
                                      name: "index_support_desk_tickets_on_open_cardinality")
      assert_equal 1, connection.select_value("SELECT COUNT(*) FROM support_desk_tickets").to_i

      run_migration("AddOpenedByToSupportDeskTickets", connection)

      assert_equal [ [ "User#7", "User#7" ] ], provenance(connection)
    end
  end

  test "the upgrade follows the schema in front of it, not today's generator setting" do
    with_scratch_database do |connection|
      run_migration("CreateSupportDeskTables", connection)
      requester_type = sql_type(connection, "requester_id")

      with_generator_primary_key(:uuid) do
        run_migration("AddOpenedByToSupportDeskTickets", connection)
      end

      assert_equal requester_type, sql_type(connection, "opened_by_id")
      assert_no_match(/uuid/i, sql_type(connection, "opened_by_id"))
    end
  end

  # The CarHey shape. DEFINED only on the PostgreSQL leg — SQLite has no uuid
  # storage of its own, so there would be nothing for the derivation to find —
  # and never skipped where it can run. The bigint case above runs on both.
  if ActiveRecord::Base.connection.adapter_name.match?(/\Apostg/i)
    test "a uuid install gets uuid provenance" do
      with_scratch_database do |connection|
        with_generator_primary_key(:uuid) do
          run_migration("CreateSupportDeskTables", connection)
          run_migration("AddOpenedByToSupportDeskTickets", connection)
        end

        assert_equal "uuid", sql_type(connection, "requester_id")
        assert_equal "uuid", sql_type(connection, "opened_by_id")
      end
    end
  end

  test "columns this migration didn't add are a refusal, not a silent skip" do
    with_scratch_database do |connection|
      run_migration("CreateSupportDeskTables", connection)
      connection.add_column :support_desk_tickets, :opened_by_type, :string

      error = assert_raises(ActiveRecord::MigrationError) do
        run_migration("AddOpenedByToSupportDeskTickets", connection)
      end

      assert_match(/already has opened_by_type/, error.message)
      assert_match(/db:migrate:up/, error.message)
      assert_not connection.index_exists?(:support_desk_tickets, [ :opened_by_type, :opened_by_id ], name: INDEX_NAME)
    end
  end

  private

  def postgresql? = ActiveRecord::Base.connection.adapter_name.match?(/\Apostg/i)

  # A database of our own: a scratch schema on PostgreSQL (one connection
  # string, one DROP … CASCADE to clean up), a temporary file on SQLite.
  def with_scratch_database
    configuration = prepare_scratch_database
    Scratch.establish_connection(configuration)
    silence_migrations { yield Scratch.connection }
  ensure
    Scratch.remove_connection
    discard_scratch_database
  end

  def prepare_scratch_database
    if postgresql?
      ActiveRecord::Base.connection.execute("DROP SCHEMA IF EXISTS #{SCRATCH_SCHEMA} CASCADE")
      ActiveRecord::Base.connection.execute("CREATE SCHEMA #{SCRATCH_SCHEMA}")
      ActiveRecord::Base.connection_db_config.configuration_hash.merge(schema_search_path: SCRATCH_SCHEMA)
    else
      @scratch_file = File.join(Dir.tmpdir, "support_desk_migration_#{SecureRandom.hex(4)}.sqlite3")
      { adapter: "sqlite3", database: @scratch_file }
    end
  end

  def discard_scratch_database
    if postgresql?
      ActiveRecord::Base.connection.execute("DROP SCHEMA IF EXISTS #{SCRATCH_SCHEMA} CASCADE")
    elsif @scratch_file && File.exist?(@scratch_file)
      File.delete(@scratch_file)
    end
  end

  def silence_migrations
    previous = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    yield
  ensure
    ActiveRecord::Migration.verbose = previous
  end

  # The dummy's migrations are the ones under test: they are verbatim copies
  # of the two templates (the drift tests keep them that way), so running
  # them IS running what a host runs.
  def run_migration(name, connection, direction = :up)
    context = ActiveRecord::MigrationContext.new(ActiveRecord::Migrator.migrations_paths)
    proxy = context.migrations.find { |candidate| candidate.name == name }
    assert_not_nil proxy, "no migration named #{name} in test/dummy/db/migrate"

    proxy.send(:migration).exec_migration(connection, direction)
  end

  def with_generator_primary_key(type)
    generators = Rails.configuration.generators
    options = generators.options[generators.orm]
    had = options.key?(:primary_key_type)
    previous = options[:primary_key_type]
    options[:primary_key_type] = type
    yield
  ensure
    had ? options[:primary_key_type] = previous : options.delete(:primary_key_type)
  end

  def sql_type(connection, column_name)
    connection.columns(:support_desk_tickets).find { |column| column.name == column_name }.sql_type
  end

  # Every case as [who asked, who opened it], so a backfill that pointed a row
  # at the wrong record could not read as a pass.
  def provenance(connection)
    rows = connection.select_rows(<<~SQL.squish)
      SELECT requester_type, requester_id, opened_by_type, opened_by_id
        FROM support_desk_tickets ORDER BY id
    SQL

    rows.map do |requester_type, requester_id, opened_by_type, opened_by_id|
      [ "#{requester_type}##{requester_id}", opened_by_type && "#{opened_by_type}##{opened_by_id}" ]
    end
  end

  def insert_desk(connection)
    connection.insert(
      "INSERT INTO support_desk_desks (key, created_at, updated_at) " \
      "VALUES ('default', #{connection.quote(Time.current)}, #{connection.quote(Time.current)})"
    )
    connection.select_value("SELECT id FROM support_desk_desks WHERE key = 'default'")
  end

  # A 0.1 row: everything the old schema demanded, and no provenance, because
  # there was nowhere to put it.
  def insert_legacy_ticket(connection, desk_id:, requester_type:, requester_id:)
    now = connection.quote(Time.current)
    reference = connection.quote("T-#{SecureRandom.hex(3).upcase}")
    connection.insert(<<~SQL.squish)
      INSERT INTO support_desk_tickets
        (desk_id, requester_type, requester_id, topic, reference, status, awaiting, priority, opened_via,
         opened_at, reopen_count, cardinality_key, created_at, updated_at)
      VALUES
        (#{connection.quote(desk_id)}, #{connection.quote(requester_type)}, #{connection.quote(requester_id)},
         'other', #{reference}, 'open', 'agent', 0, 'in_app', #{now}, 0,
         #{connection.quote("topic:other:#{requester_id}")}, #{now}, #{now})
    SQL
  end
end
