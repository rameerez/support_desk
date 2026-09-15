# frozen_string_literal: true

class ApplicationController < ActionController::Base
  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end
  helper_method :current_user

  def authenticate_user!
    head :unauthorized unless current_user
  end

  # Something that is emphatically NOT a requester, so a test can point
  # `config.current_requester_method` at the wrong thing and see what the
  # engine says about it.
  def current_order
    Order.first
  end
end
