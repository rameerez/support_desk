# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/support_desk/console_generator"
require "ripper"

class ConsoleGeneratorTest < Rails::Generators::TestCase
  tests SupportDesk::Generators::ConsoleGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  VIEWS = %w[
    index.html.erb show.html.erb _tabs.html.erb _ticket_row.html.erb _context_card.html.erb
    _transcript.html.erb _message.html.erb _composer.html.erb _assignment.html.erb _actions.html.erb
    _timeline.html.erb _nav_badge.html.erb
  ].freeze

  test "it writes a controller, an admin resource and the whole view set" do
    run_generator

    assert_file "app/controllers/madmin/support_tickets_controller.rb" do |controller|
      assert_match(/module Madmin/, controller)
      assert_match(/class SupportTicketsController < Madmin::ApplicationController/, controller)
      assert_match(/include SupportDesk::Console$/, controller)
      assert_match(/include SupportDesk::Console::Index/, controller)
      assert_match(/def current_agent = current_user/, controller)
      assert_match(/def show/, controller)
    end

    assert_file "app/madmin/resources/support_ticket_resource.rb" do |resource|
      assert_match(/class SupportTicketResource < Madmin::Resource/, resource)
      assert_match(/model SupportDesk::Ticket/, resource)
      assert_match(/url_helpers\.madmin_support_tickets_path/, resource)
      assert_match(/url_helpers\.madmin_support_ticket_path/, resource)
    end

    VIEWS.each { |view| assert_file "app/views/madmin/support_tickets/#{view}" }
  end

  test "the generated views are byte-identical to the ones the engine renders" do
    run_generator

    VIEWS.each do |view|
      engine_copy = File.read(File.join(SupportDesk::Generators::ConsoleGenerator::VIEWS_ROOT, view))

      assert_file "app/views/madmin/support_tickets/#{view}" do |generated|
        assert_equal engine_copy, generated,
                     "#{view} has drifted from the console engine's copy — there is only one source of truth"
      end
    end
  end

  test "every generated file is syntactically valid" do
    run_generator

    assert_valid_ruby read_generated("app/controllers/madmin/support_tickets_controller.rb")
    assert_valid_ruby read_generated("app/madmin/resources/support_ticket_resource.rb")

    VIEWS.each do |view|
      source = read_generated("app/views/madmin/support_tickets/#{view}")

      assert_valid_ruby compile_erb(source), "#{view} does not compile"
    end
  end

  test "the routes the generated files reference actually resolve" do
    run_generator

    # The resource template points madmin's own links at the console's
    # routes, which only exist because the host drew `concerns:
    # :support_console`. The dummy app draws exactly the line the generator
    # prints, so these helpers are the real ones a host would get.
    helpers = Rails.application.routes.url_helpers

    assert_respond_to helpers, :madmin_support_tickets_path
    assert_respond_to helpers, :madmin_support_ticket_path
    assert_respond_to helpers, :reply_madmin_support_ticket_path
    assert_respond_to helpers, :next_madmin_support_tickets_path
  end

  test "the dummy host's controller is what this generator writes" do
    # The suite's Layer 2 tests run against test/dummy's madmin controller.
    # This is what makes them a test of the GENERATOR's output rather than
    # of a hand-written lookalike.
    run_generator

    assert_file "app/controllers/madmin/support_tickets_controller.rb" do |generated|
      dummy = File.read(File.expand_path("../dummy/app/controllers/madmin/support_tickets_controller.rb", __dir__))

      assert_equal generated, dummy,
                   "test/dummy's console controller has drifted from the generator template — re-render it"
    end
  end

  test "running it twice changes nothing" do
    run_generator
    edited = "# my own note\n" + read_generated("app/views/madmin/support_tickets/index.html.erb")
    File.write(File.join(destination_root, "app/views/madmin/support_tickets/index.html.erb"), edited)

    output = run_generator

    assert_match(/skip/, output)
    assert_equal edited, read_generated("app/views/madmin/support_tickets/index.html.erb"),
                 "a second run must leave your edits alone"
  end

  test "--force takes the gem's defaults back" do
    run_generator
    path = File.join(destination_root, "app/views/madmin/support_tickets/index.html.erb")
    File.write(path, "# mine\n")

    run_generator [ "madmin", "--force" ]

    assert_equal File.read(File.join(SupportDesk::Generators::ConsoleGenerator::VIEWS_ROOT, "index.html.erb")),
                 File.read(path)
  end

  test "a namespace other than madmin gets the controller and views, but no madmin resource" do
    run_generator [ "backoffice" ]

    assert_file "app/controllers/backoffice/support_tickets_controller.rb" do |controller|
      assert_match(/module Backoffice/, controller)
      assert_match(/< Backoffice::ApplicationController/, controller)
      assert_match(/namespace :backoffice do/, controller)
    end

    assert_file "app/views/backoffice/support_tickets/index.html.erb"
    assert_no_file "app/madmin/resources/support_ticket_resource.rb"
  end

  test "it prints the route line, the badge line and the settings to check" do
    output = run_generator

    assert_match(/resources :support_tickets, only: %i\[index show\], concerns: :support_console/, output)
    assert_match(%r{madmin/support_tickets/nav_badge}, output)
    assert_match(/config\.visible_desks_for/, output)
    assert_match(/config\.authorize_console/, output)
  end

  private

  def read_generated(path) = File.read(File.join(destination_root, path))

  # Rails ERB, not plain Erubi: `<%= … do %>` blocks are a Rails dialect,
  # and plain Erubi turns every one of them into a syntax error.
  def compile_erb(source) = ActionView::Template::Handlers::ERB::Erubi.new(source).src

  def assert_valid_ruby(source, message = nil)
    assert_not_nil Ripper.sexp(source), message || "expected valid Ruby"
  end
end
