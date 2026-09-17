# frozen_string_literal: true

require "test_helper"
# `$CHILD_STATUS` is English's name for `$?`, and nothing in this file
# would otherwise load it.
require "English"

# `require "support_desk"` outside Rails — a rake task, a script, a boot that
# has not reached the models yet — loads the spine, and the console concern is
# part of that spine (the ConsoleEngine has to isolate its namespace before it
# can exist). ActiveRecord is NOT loaded by it: chats is a dependency,
# ActiveRecord is not required by either gem's entry point.
#
# So a constant like `ActiveRecord::RecordInvalid` named at load time in the
# console's rescue list would turn that require into a NameError. It is
# checked at RUNTIME instead, and this is the test that keeps it that way —
# in a genuinely fresh process, because everything is already loaded in this
# one.
class ConsoleBootTest < ActiveSupport::TestCase
  GEM_ROOT = File.expand_path("../..", __dir__)

  test "require \"support_desk\" in a fresh process loads the console without ActiveRecord" do
    script = <<~RUBY
      require "support_desk"

      raise "ActiveRecord was loaded by the require" if defined?(ActiveRecord)
      raise "the console concern didn't load" unless defined?(SupportDesk::Console)
      raise "the routing concern didn't load" unless defined?(SupportDesk::ConsoleRoutes)

      names = SupportDesk::Console::RESCUED_ERRORS.map(&:name)
      raise "RESCUED_ERRORS names ActiveRecord: \#{names.inspect}" if names.any? { |n| n.start_with?("ActiveRecord") }
      raise "RESCUED_ERRORS lost Chats::Error" unless names.include?("Chats::Error")

      print "ok"
    RUBY

    assert_equal "ok", run_in_fresh_process(script)
  end

  test "the console's own tables are readable without a database" do
    script = <<~RUBY
      require "support_desk"

      print SupportDesk::Console::COLLECTION_VERBS.keys.join(",")
    RUBY

    assert_equal "next,open_conversation", run_in_fresh_process(script)
  end

  test "Rails discovers the backfill task exactly once" do
    script = <<~RUBY
      require #{File.expand_path("test/dummy/config/environment", GEM_ROOT).inspect}
      require "rake"
      Rails.application.load_tasks
      puts "backfill_actions=\#{Rake::Task["support_desk:backfill_opened_by"].actions.size}"
    RUBY
    assert_match(/(?:\A|\n)backfill_actions=1\n?\z/, run_in_fresh_process(script))
  end

  private

  def run_in_fresh_process(script)
    file = File.join(Dir.tmpdir, "support_desk_boot_#{SecureRandom.hex(4)}.rb")
    File.write(file, script)
    output = IO.popen([ Gem.ruby, "-I", File.join(GEM_ROOT, "lib"), file ], err: [ :child, :out ], &:read)

    assert_predicate $CHILD_STATUS, :success?, "the fresh process failed: #{output}"
    output
  ensure
    File.delete(file) if file && File.exist?(file)
  end
end
