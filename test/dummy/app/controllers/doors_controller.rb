# frozen_string_literal: true

# A stand-in for ANY host page that puts a support door on itself — a ride, an
# order, a profile. It exists so the helpers are tested where hosts actually
# call them: in a host view, outside the engine, with the mounted route proxy.
class DoorsController < ApplicationController
  def show
    @order = Order.find_by(id: params[:order_id])
  end
end
