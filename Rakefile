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

desc "Everything a pull request has to pass: tests, linter, security scan"
# Clear SimpleCov's merged resultset first. It merges results across runs, so
# a stale one from an earlier single-file run drags the total under the
# coverage floor and fails the gate for a regression that does not exist.
task :clear_coverage do
  rm_rf "coverage"
end

task ci: %i[clear_coverage test rubocop brakeman]

task default: :test
