# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Whose desks this request serves, the way a multi-tenant host says it.
  # Nothing is set unless a test logged in with an owner.
  before_action { SupportDesk::Current.owner = User.find_by(id: session[:support_owner_id]) if session[:support_owner_id] }

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
