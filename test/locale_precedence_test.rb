# frozen_string_literal: true

require "test_helper"

# Gem first, host last.
#
# A host rewords our copy by shipping the same key in its own locale file, and
# it must win. That only holds while the gem's locales arrive through
# Rails::Engine's :add_locales (railtie paths are unshifted ahead of the app's);
# a manual `app.config.i18n.load_path +=` in the engine appends a SECOND copy
# that lands after the host's files and silently overrides them. This gem
# shipped that bug, and the only symptom was a host override that did nothing.
class LocalePrecedenceTest < ActiveSupport::TestCase
  # The dummy app ships config/locales/host_override.es.yml, which redefines
  # one of our keys the way a real host would.
  test "a host's own locale file outranks the gem's" do
    I18n.with_locale(:es) do
      assert_equal "Esperando al equipo (del host)",
                   I18n.t("support_desk.queue.tabs.awaiting"),
                   "the gem is overriding the host's copy — check for a manual i18n.load_path append in the engine"
    end
  end

  test "the gem still supplies every key the host does not override" do
    I18n.with_locale(:es) do
      assert_equal "Sin asignar", I18n.t("support_desk.queue.tabs.unassigned")
    end
  end

  test "the gem's locale files are loaded once per path, not once per reload" do
    ours = I18n.load_path.select { |p| p.include?("support_desk") && p.end_with?(".yml") }

    assert_equal ours.uniq.size, ours.size,
                 "a locale file appears more than once in I18n.load_path: #{ours.tally.select { |_, n| n > 1 }.inspect}"
  end
end
