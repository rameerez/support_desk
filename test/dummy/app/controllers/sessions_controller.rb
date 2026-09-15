# frozen_string_literal: true

# Test-only "auth": integration tests POST /test_login to act as a user.
class SessionsController < ApplicationController
  def create
    session[:user_id] = params[:user_id]
    head :no_content
  end

  def home
    render plain: "dummy"
  end
end
