# frozen_string_literal: true

require "test_helper"

# The Hotwire Native path-configuration rules a host splats into its own
# `rules` array. The SHAPE is the contract — native apps parse this JSON —
# so it is pinned here rather than described in a doc.
class NativePathRulesTest < ActiveSupport::TestCase
  test "it describes the two requester surfaces, and nothing else" do
    rules = SupportDesk.native_path_rules(mount: "/support", title: "Soporte")

    assert_equal 2, rules.size
    assert_equal %i[patterns properties comment], rules.first.keys
    assert(rules.all? { |rule| rule[:properties][:context] == "default" })
    assert(rules.all? { |rule| rule[:properties][:title] == "Soporte" })
  end

  test "the list matches the mount point, with or without a trailing slash or a query" do
    pattern = Regexp.new(SupportDesk.native_path_rules(mount: "/support").first[:patterns].first)

    assert_match pattern, "/support"
    assert_match pattern, "/support/"
    assert_match pattern, "/support?from=nav"
    assert_no_match pattern, "/support/new"
    assert_no_match pattern, "/supported"
  end

  test "the wizard matches every one of its steps, because every step is a URL" do
    pattern = Regexp.new(SupportDesk.native_path_rules(mount: "/support").last[:patterns].first)

    assert_match pattern, "/support/new"
    assert_match pattern, "/support/new?topic=payments/withdrawal"
    assert_match pattern, "/support/new?about=abc123"
    assert_no_match pattern, "/support"
    assert_no_match pattern, "/support/tickets/1"
  end

  test "the wizard never pulls to refresh, because that would discard what was typed" do
    wizard = SupportDesk.native_path_rules(mount: "/support").last

    assert_equal false, wizard[:properties][:pull_to_refresh_enabled]
    assert_equal true, SupportDesk.native_path_rules(mount: "/support").first[:properties][:pull_to_refresh_enabled]
  end

  test "a regex-flavoured mount point is escaped, not interpolated" do
    pattern = Regexp.new(SupportDesk.native_path_rules(mount: "/a.b").first[:patterns].first)

    assert_match pattern, "/a.b"
    assert_no_match pattern, "/axb"
  end

  test "it defaults to where the engine is mounted and what the desk is called" do
    rules = SupportDesk.native_path_rules

    assert_equal "Soporte", rules.first[:properties][:title]
    assert_match Regexp.new(rules.first[:patterns].first), "/messages/support"
  end

  test "it says so when it can't tell where the engine is mounted" do
    error = assert_raises(SupportDesk::ConfigurationError) { SupportDesk.native_path_rules(mount: "") }

    assert_match(/mount SupportDesk::Engine/, error.message)
  end

  test "the rules survive the round trip a host puts them through" do
    rules = SupportDesk.native_path_rules(mount: "/support")
    round_tripped = JSON.parse(rules.to_json)

    assert_equal "default", round_tripped.first.dig("properties", "context")
    assert_equal rules.first[:patterns], round_tripped.first["patterns"]
  end
end
