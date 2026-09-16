# frozen_string_literal: true

require "test_helper"

# `concerns: :support_console` is the whole of Layer 2's routing surface —
# one word in a host's routes file. These tests pin what that word draws,
# and the one ordering detail that would break silently.
class ConsoleRoutingTest < ActionDispatch::IntegrationTest
  test "the concern draws every verb as a member POST in a host namespace" do
    SupportDesk::ConsoleRoutes::MEMBER_VERBS.each do |verb|
      assert_routing({ method: "post", path: "/madmin/support_tickets/7/#{verb}" },
                     { controller: "madmin/support_tickets", action: verb.to_s, id: "7" })
    end
  end

  test "the concern draws next as a collection GET" do
    assert_routing({ method: "get", path: "/madmin/support_tickets/next" },
                   { controller: "madmin/support_tickets", action: "next" })
  end

  test "next is not swallowed by the show route" do
    # A `resources` block draws its concerns BEFORE its own member mappings,
    # which is the only reason /next doesn't recognize as show(id: "next").
    # If that ever changes, this is the test that says so.
    recognized = Rails.application.routes.recognize_path("/madmin/support_tickets/next", method: :get)

    assert_equal "next", recognized[:action]
    assert_nil recognized[:id]
  end

  test "the host's own index and show are untouched" do
    assert_routing "/madmin/support_tickets", controller: "madmin/support_tickets", action: "index"
    assert_routing "/madmin/support_tickets/7", controller: "madmin/support_tickets", action: "show", id: "7"
  end

  test "the mounted console engine draws the same routes from the same concern" do
    routes = SupportDesk::ConsoleEngine.routes

    assert_equal "index", routes.recognize_path("/", method: :get)[:action]
    assert_equal "next", routes.recognize_path("/next", method: :get)[:action]

    SupportDesk::ConsoleRoutes::MEMBER_VERBS.each do |verb|
      recognized = routes.recognize_path("/7/#{verb}", method: :post)

      assert_equal verb.to_s, recognized[:action], "the engine is missing #{verb}"
      assert_equal "support_desk/console/tickets", recognized[:controller]
    end
  end

  test "registering the concern is idempotent" do
    assert_predicate SupportDesk::ConsoleRoutes, :installed?
    assert_not SupportDesk::ConsoleRoutes.install!, "a second install! should be a no-op"
  end

  test "the concern reaches a route set that isn't the app's" do
    # Seeding happens per Mapper, so every route set gets it — an engine's,
    # a test's, an admin framework that draws its own.
    set = ActionDispatch::Routing::RouteSet.new
    set.draw { resources :sessions, only: [], concerns: :support_console }

    assert_equal "reply", set.recognize_path("/sessions/7/reply", method: :post)[:action]
  end

  test "the Mapper patch forwards whatever Rails hands its initializer" do
    # `Mapper#initialize`'s signature is private Rails API, so the patch
    # forwards with `(...)` and takes no view on the arity. What WOULD break
    # a host silently is a renamed initializer or a `@concerns` Hash that
    # stopped being the mechanism — this is the test that catches either,
    # rather than a routes file quietly losing the concern.
    ancestors = ActionDispatch::Routing::Mapper.ancestors

    assert_operator ancestors.index(SupportDesk::ConsoleRoutes::MapperExtension), :<,
                    ancestors.index(ActionDispatch::Routing::Mapper),
                    "the extension has to come BEFORE Mapper for its initialize to run"

    set = ActionDispatch::Routing::RouteSet.new
    mapper = ActionDispatch::Routing::Mapper.new(set)

    assert_same set, mapper.instance_variable_get(:@set),
                "Mapper#initialize no longer stores the route set it was given"
    assert_equal({ SupportDesk::ConsoleRoutes::CONCERN => SupportDesk::ConsoleRoutes::Drawer },
                 mapper.instance_variable_get(:@concerns).transform_values(&:class),
                 "the concern is no longer seeded into @concerns"
                )
  end

  test "a host can register the concern by hand, without the patch" do
    # The supported way out for anybody who would rather not have a prepend
    # on Mapper at all. Documented in the README, so it has to keep working.
    set = ActionDispatch::Routing::RouteSet.new
    set.draw do
      SupportDesk::ConsoleRoutes.register(self)
      resources :sessions, only: [], concerns: :support_console
    end

    assert_equal "reply", set.recognize_path("/sessions/7/reply", method: :post)[:action]
  end

  test "using the concern outside a resource scope says so, and names the gem" do
    # Rails' own ArgumentError ("can't use collection outside resource(s)
    # scope") is true and mentions nothing that would send you here.
    set = ActionDispatch::Routing::RouteSet.new

    error = assert_raises(SupportDesk::ConfigurationError) do
      set.draw { concerns :support_console }
    end

    assert_match(/concerns: :support_console/, error.message)
    assert_match(/inside a `resources` block/, error.message)
    assert_match(/resources :support_tickets/, error.message)
  end

  test "a host concern of the same name wins" do
    # The patch seeds :support_console and then gets out of the way: the
    # host's own `concern` call happens later in the draw block, so theirs
    # is the one in the Hash by the time `concerns:` reads it.
    set = ActionDispatch::Routing::RouteSet.new
    set.draw do
      concern(:support_console) { |_options| collection { get :pinged } }
      resources :sessions, only: [], concerns: :support_console
    end

    assert_equal "pinged", set.recognize_path("/sessions/pinged", method: :get)[:action]
    assert_raises(ActionController::RoutingError) { set.recognize_path("/sessions/7/reply", method: :post) }
  end
end
