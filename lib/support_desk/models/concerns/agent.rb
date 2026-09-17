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
      SupportDesk.eligible?(self, self.class.support_desk_agent_options[:if])
    end

    # Write first, as the desk — the mirror of Requester#ask_support!.
    #
    #   lucia.open_support_conversation_with!(alice, "Vimos que tu retirada rebotó", about: withdrawal)
    #   lucia.open_support_conversation_with!(alice, "Tu DNI no se lee bien", topic: :verification)
    #
    # Not `message!`: that is a personal chat from Lucía. This speaks as the
    # desk, signs the message with her name, seats her on the case, and lands
    # in Alice's inbox as "Soporte". If Alice already has this conversation
    # open, the message joins it as an ordinary reply, under the desk's reply
    # policy — which can leave the case with whoever already holds it.
    # Returns the SupportDesk::Ticket.
    #
    # Raises NotARequester (nobody to write to), NotAllowed (including an
    # agent aiming at themselves: an agent who needs help asks for it),
    # NotSupportable, UnknownTopic.
    def open_support_conversation_with!(requester, message, about: nil, topic: nil, files: [], via: :in_app,
                                        desk: nil, request: nil)
      SupportDesk::Ticket.ensure_requester!(requester)

      if SupportDesk::Ticket.same_actor?(requester, self)
        raise SupportDesk::NotAllowed,
              "#{self.class}##{id} can't open a support conversation with themselves — an agent who needs " \
              "help asks for it (ask_support!), and the case would be theirs to answer"
      end

      SupportDesk::Ticket.open!(
        requester: requester,
        by: self,
        message: message,
        about: about,
        topic: topic,
        files: files,
        via: via,
        desk: desk || requester.support_desk,
        requester_role: requester.class.support_desk_requester_options[:as],
        request: request
      )
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
