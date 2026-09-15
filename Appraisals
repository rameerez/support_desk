# frozen_string_literal: true

# Test the minimum supported Rails version (matches the gemspec floor).
# `ActiveRecord.after_all_transactions_commit` — how every event this gem
# emits gets out only after the transition it describes is durable — is a
# Rails 7.2 API, which is what sets the floor.
appraise "rails-7.2" do
  gem "rails", "~> 7.2.0"
end

appraise "rails-8.0" do
  gem "rails", "~> 8.0.0"
end

# Test the latest Rails version — this is the default/main Gemfile anyway.
appraise "rails-8.1" do
  gem "rails", "~> 8.1.0"
end
