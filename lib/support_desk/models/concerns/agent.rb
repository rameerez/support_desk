# frozen_string_literal: true

module SupportDesk
  # Included by `acts_as_support_agent`. Agents are never chats participants
  # — the desk sends, the agent *authors* — so a model becomes an agent with
  # no messaging setup at all.
  #
  #   class User < ApplicationRecord
  #     acts_as_support_agent if: :admin?
  #   end
  #
  #   lucia.support_agent?      # => true
  #   lucia.support_queue.mine  # => relation
  module Agent
    extend ActiveSupport::Concern

    included do
      class_attribute :support_desk_agent_options, instance_writer: false,
                                                   default: { if: nil, kind: :human }.freeze

      has_many :support_assignments,
               class_name: "SupportDesk::Assignment",
               as: :agent,
               inverse_of: :agent,
               dependent: :nullify

      has_many :support_tickets_assigned,
               class_name: "SupportDesk::Ticket",
               as: :assignee,
               inverse_of: :assignee,
               dependent: :nullify
    end

    class_methods do
      def support_agent_class? = true
    end

    # Whether this record may answer tickets right now — the `if:` condition
    # from the macro, honoured.
    def support_agent?
      condition = self.class.support_desk_agent_options[:if]
      return true if condition.nil?
      return !!public_send(condition) if condition.is_a?(Symbol)

      !!condition.call(self)
    end

    # :human or :ai. Bots disclose themselves through this (04).
    def support_agent_kind
      self.class.support_desk_agent_options[:kind]
    end

    # The signature requesters see under an answer.
    def support_agent_name
      %i[public_name display_name name].each do |method|
        value = try(method)
        return value.to_s if value.present?
      end

      "#{self.class.model_name.human} #{id}"
    end

    # Anything `image_tag` accepts, or nil.
    def support_agent_avatar = try(:avatar)

    # Whether the desk should route or notify this agent right now. True by
    # default: hosts back it with a schedule, a presence bit, or the duty
    # table that ships in 0.3.
    def on_duty? = true

    # How many open tickets this agent can hold; nil is unlimited.
    def support_capacity = nil

    # This agent's view of the desk: tabs, counts, badge, next ticket.
    def support_queue(desk: nil)
      SupportDesk::Queue.for(self, desk: desk)
    end
  end
end
