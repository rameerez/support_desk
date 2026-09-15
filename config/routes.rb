# frozen_string_literal: true

# The requester-facing engine:
#
#   mount SupportDesk::Engine => "/support"
#
# Everything a person who needs help touches lives here — the wizard, their
# list of cases, and the doors into them. The agent console is BYOUI: query
# objects and presenters (Layer 1), a controller concern and a routing
# concern (Layer 2), or the generated console (Layer 3). See the README.
SupportDesk::Engine.routes.draw do
end
