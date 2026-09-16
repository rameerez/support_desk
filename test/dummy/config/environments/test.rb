# frozen_string_literal: true

# The dummy host's test environment.
#
# It exists mainly to keep the suite QUIET. Without it the dummy runs on the
# framework defaults, which log every SQL statement, every render and every
# request at :debug — about 80 MB of test/dummy/log/test.log for one full
# run, rotated by `config.log_file_size` at 100 MB. That is how a 100 MB log
# ended up committed to this repo. A gem's suite has no business writing
# 80 MB to a contributor's disk.
#
# Quiet is NOT silent: Minitest's own output, `config.active_support
# .deprecation = :stderr` (set in application.rb) and every exception
# backtrace all go to the terminal, not to the log. Set VERBOSE_TEST_LOG=1
# to get the old firehose back when you are debugging one test.
Rails.application.configure do
  config.enable_reloading = false

  # Eager loading is what the suite wants (autoload problems become boot
  # failures), but it also HIDES the bug where an engine constant is never
  # referenced and its on_load hooks never fire. One test boots a second
  # process with this off to prove the engine works the way a development
  # host runs it — see test/engine_autoload_test.rb.
  config.eager_load = ENV["SUPPORT_DESK_EAGER_LOAD"] != "false"

  if ENV["VERBOSE_TEST_LOG"].present?
    config.log_level = :debug
  else
    # IO::NULL rather than a level alone: the level silences framework
    # logging, this also swallows anything a host or gem writes to
    # Rails.logger directly.
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.log_level = :error
  end

  # The multi-line SQL source annotations are the single biggest contributor
  # to the old log, and they cost time to build even when nothing reads them.
  config.active_record.verbose_query_logs = false
  config.active_job.verbose_enqueue_logs = false

  # RAISE what the app can't handle, instead of rendering a 500 page into a
  # response body nobody looks at. With the log silenced, a raised exception
  # is where a failing request tells you what went wrong — and the rescuable
  # ones (RecordNotFound → 404) still render, because tests assert on those.
  config.action_dispatch.show_exceptions = :rescuable
end
