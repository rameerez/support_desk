# frozen_string_literal: true

require "test_helper"
require "yaml"

# The gem ships Spanish and English, and they have to say the same things.
# A key added to one file and forgotten in the other is invisible until
# somebody switches locale and reads "translation missing" on a screen that
# was working an hour ago.
class LocalesTest < ActiveSupport::TestCase
  LOCALE_ROOT = File.expand_path("../config/locales", __dir__)

  # The keys the "writing first" work added, spelled out rather than derived:
  # this is the list the plan wrote down, and it should fail here if somebody
  # renames one without meaning to.
  WRITE_FIRST_KEYS = %w[
    support_desk.thread.opened_by_support
    support_desk.thread.unavailable_notice
    support_desk.tickets.state.opened_by_support
    support_desk.console.actions.new_conversation
    support_desk.console.new_conversation.title
    support_desk.console.new_conversation.requester
    support_desk.console.new_conversation.requester_query
    support_desk.console.new_conversation.requester_hint
    support_desk.console.new_conversation.about
    support_desk.console.new_conversation.topic
    support_desk.console.new_conversation.message
    support_desk.console.new_conversation.send
    support_desk.console.new_conversation.cancel
    support_desk.console.new_conversation.signed_as
    support_desk.console.flashes.message_sent
    support_desk.console.errors.unknown_requester
    support_desk.console.errors.not_a_requester
    support_desk.console.errors.invalid_requester
    support_desk.console.errors.invalid_subject
    support_desk.console.errors.invalid_input
    support_desk.console.errors.no_requester_lookup
    support_desk.console.errors.writing_to_yourself
    support_desk.console.errors.off_duty
    support_desk.console.errors.attachments_again
    support_desk.console.row.opened_by_support
    support_desk.console.context.opened_by
    support_desk.console.context.not_recorded
    support_desk.console.context.unavailable
  ].freeze

  test "es and en ship exactly the same keys" do
    %w[support_desk support_desk.console].each do |file|
      spanish = keys_in("#{file}.es.yml")
      english = keys_in("#{file}.en.yml")

      assert_equal [], spanish - english, "#{file}: keys in es that en hasn't got"
      assert_equal [], english - spanish, "#{file}: keys in en that es hasn't got"
    end
  end

  test "every key writing first added exists in both languages" do
    WRITE_FIRST_KEYS.each do |key|
      %i[es en].each do |locale|
        assert I18n.exists?(key, locale), "no #{locale} copy for #{key}"
      end
    end
  end

  test "the Spanish copy has no dashes in it" do
    # The host's rule, and the gem's Spanish follows it: a dash reads as a
    # typo in customer copy, and support copy is customer copy.
    offenders = flatten(YAML.load_file(File.join(LOCALE_ROOT, "support_desk.es.yml")).fetch("es"))
                .merge(flatten(YAML.load_file(File.join(LOCALE_ROOT, "support_desk.console.es.yml")).fetch("es")))
                .select { |_key, value| value.is_a?(String) && value.match?(/\s[—–-]\s/) }

    assert_empty offenders, "Spanish copy with a dash in it: #{offenders.keys.join(", ")}"
  end

  private

  def keys_in(file)
    YAML.load_file(File.join(LOCALE_ROOT, file)).values.first.then { |tree| flatten(tree).keys.sort }
  end

  def flatten(tree, prefix = "")
    tree.each_with_object({}) do |(key, value), flat|
      path = "#{prefix}#{key}"
      value.is_a?(Hash) ? flat.merge!(flatten(value, "#{path}.")) : flat[path] = value
    end
  end
end
