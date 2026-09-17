# frozen_string_literal: true

# The turnkey console:
#
#   mount SupportDesk::ConsoleEngine => "/admin/support"
#
# `path: ""` keeps the URLs short under the mount point: the queue is
# /admin/support, a case is /admin/support/:id, and every verb is a POST to
# /admin/support/:id/<verb>. The member and collection routes come from the
# SAME `:support_console` concern a host writes in their own routes file —
# the turnkey console gets no private API.
SupportDesk::ConsoleEngine.routes.draw do
  resources :tickets, path: "", only: %i[index show new], concerns: :support_console

  root to: "tickets#index"
end
