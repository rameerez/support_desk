# frozen_string_literal: true

# Test-only "auth": integration tests POST /test_login to act as a user, and
# system tests (which can't POST) visit GET /test_login/:user_id.
class SessionsController < ApplicationController
  def create
    session[:user_id] = params[:user_id]
    request.get? ? render(plain: "ok") : head(:no_content)
  end

  def home
    render plain: "dummy"
  end
end
