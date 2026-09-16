# frozen_string_literal: true

require_relative "lib/support_desk/version"

Gem::Specification.new do |spec|
  spec.name = "support_desk"
  spec.version = SupportDesk::VERSION
  spec.authors = [ "rameerez" ]
  spec.email = [ "rubygems@rameerez.com" ]

  spec.summary = "Add customer support (tickets that are conversations) to your Rails app"
  spec.description = "support_desk adds a customer support desk to any Rails app: tickets that are conversations. A requester asks for help about something in your app (a ride, an order, a withdrawal) or about nothing in particular, your desk answers, humans or bots sign the answers, and your team works a queue. It is a product gem on the `chats` kernel: chats owns the transcript, realtime, attachments, read state and moderation; support_desk owns cases, topics, assignment, routing and the console API. One macro makes a model ask for help (`has_support_tickets`), one makes a domain record something to ask about (`supportable`), one makes a person answer (`acts_as_support_agent`). Topics are a tree defined in code that drives the wizard, the picker, routing and metrics; assignment is a history, not a column; every transition writes an append-only event row and emits an error-isolated event your app can subscribe to. Batteries included on the user side (a mountable engine with ejectable views), bring-your-own-UI on the agent side (query objects, presenters, a controller concern and a console generator), with no runtime dependency on any admin framework."
  spec.homepage = "https://github.com/rameerez/support_desk"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        # `screenshots/` is README furniture — ~750 KB of PNGs that the README
        # loads over https from the repo, so nothing inside the gem needs them.
        f.start_with?(*%w[bin/ test/ spec/ features/ docs/ screenshots/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = [ "lib" ]

  # Runtime dependencies. `chats` is the kernel this gem is a product on: it
  # owns the transcript (conversations, messages, read state, realtime,
  # attachments, moderation) and support_desk owns everything a *case* needs
  # on top of it. Everything else a desk touches (notifications, admin UI,
  # pagination, inbound mail) is a host-side integration wired through hooks,
  # never a forced dependency.
  spec.add_dependency "activerecord", ">= 7.2.0", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.2.0", "< 9.0"
  # ~> 0.3, not ~> 0.2: Desk declares `acts_as_messager verified: true`, a
  # keyword chats 0.2.x does not accept, so a host resolving 0.2 would fail at
  # class definition with ArgumentError long before `doctor` could explain it.
  spec.add_dependency "chats", "~> 0.3", ">= 0.3.2"
  spec.add_dependency "globalid", "~> 1.0"
  spec.add_dependency "railties", ">= 7.2.0", "< 9.0"
end
