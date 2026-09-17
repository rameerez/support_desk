# frozen_string_literal: true

begin
  require "bundler/setup"
rescue LoadError
  puts "You must `gem install bundler` and `bundle install` to run rake tasks"
end

require "bundler/gem_tasks"

require "rdoc/task"

RDoc::Task.new(:rdoc) do |rdoc|
  rdoc.rdoc_dir = "rdoc"
  rdoc.title = "SupportDesk"
  rdoc.options << "--line-numbers"
  rdoc.rdoc_files.include("README.md")
  rdoc.rdoc_files.include("lib/**/*.rb")
end

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

# `db:migrate:reset` — the command the README and CI give for the PostgreSQL
# leg — is `["db:drop", "db:create", "db:schema:dump", "db:migrate"]` in
# ActiveRecord's own databases.rake. That third step is hardwired: it ignores
# the dummy's `config.active_record.dump_schema_after_migration = false`,
# which is why plain `rake db:migrate` leaves no dump and this task does.
#
# The dump is stamped with the Rails version that wrote it
# (`ActiveRecord::Schema[8.1]`), and every later leg's `db:test:load_schema`
# prefers a schema.rb over the migrations — so one PostgreSQL run made the
# 7.2 Appraisal die with "Unknown migration version 8.1" until the file was
# deleted by hand. The dummy migrates from db/migrate and never from a dump,
# so the artifact has no reader: throw it away where it is made.
if Rake::Task.task_defined?("db:migrate:reset")
  Rake::Task["db:migrate:reset"].enhance { rm_f "test/dummy/db/schema.rb" }
end

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.verbose = false
end

desc "Lint with rubocop-rails-omakase"
task :rubocop do
  sh "bundle exec rubocop"
end

# The engine has controllers and a generated console, so it gets scanned
# like an app. `--force-scan` because a gem is not a Rails app root.
desc "Scan for security problems with brakeman"
task :brakeman do
  sh "bundle exec brakeman --no-pager --quiet --force-scan ."
end

# Clear SimpleCov's merged resultset first. It merges results across runs, so
# a stale one from an earlier single-file run drags the total under the
# coverage floor and fails the gate for a regression that does not exist.
desc "Delete the merged coverage resultset so the next run starts clean"
task :clear_coverage do
  rm_rf "coverage"
end

desc "Everything a pull request has to pass: tests, linter, security scan"
task ci: %i[clear_coverage test rubocop brakeman]

task default: :test
