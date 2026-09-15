# frozen_string_literal: true

# The dummy app boots against the gem's own Gemfile (set by Bundler / the
# Appraisal matrix), NOT a Gemfile inside test/dummy — there isn't one.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)

require "bundler/setup"
