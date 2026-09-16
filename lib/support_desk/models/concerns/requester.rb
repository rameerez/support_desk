# frozen_string_literal: true

module SupportDesk
  # Included by `has_support_tickets`. Adds exactly four methods — the whole
  # requester side of the gem:
  #
  #   alice.ask_support!("El viaje no aparece verificado", about: ride)
  #   alice.support_tickets.open.about(ride)
  #   alice.awaiting_support_reply?
  #   alice.unread_support_count
  module Requester
    extend ActiveSupport::Concern

    included do
      class_attribute :support_desk_requester_options, instance_writer: false,
                                                       default: { desk: :default, as: nil }.freeze

      has_many :support_tickets,
               class_name: "SupportDesk::Ticket",
               as: :requester,
               inverse_of: :requester,
               dependent: :restrict_with_error
    end

    class_methods do
      def support_desk_key = support_desk_requester_options[:desk]
    end

    # Open a ticket and say the first thing. Returns the SupportDesk::Ticket
    # — the existing open one when this requester already has a ticket about
    # the same record (or, for free-form tickets, the same topic).
    #
    #   alice.ask_support!("No me han pagado", about: withdrawal)
    #   alice.ask_support!("¿Cómo borro mi cuenta?", topic: :account)
    #
    # Raises NotSupportable, UnknownTopic, NotAllowed, RateLimited,
    # TooManyOpenTickets.
    def ask_support!(message, about: nil, topic: nil, files: [], via: :in_app)
      key = self.class.support_desk_requester_options[:desk]
      desk = SupportDesk.desk(key) ||
             raise(SupportDesk::ConfigurationError,
                   "#{self.class} writes to desk #{key.inspect}, which isn't configured — " \
                   "its tickets would silently land on the default desk")

      SupportDesk::Ticket.open!(
        requester: self,
        message: message,
        about: about,
        topic: topic,
        files: files,
        via: via,
        desk: desk,
        requester_role: self.class.support_desk_requester_options[:as]
      )
    end

    # True when any of this requester's open tickets is waiting on the desk.
    def awaiting_support_reply?
      support_tickets.not_closed.awaiting_reply.exists?
    end

    # Unread messages across every support conversation this requester has,
    # counted against the chats read horizon — the number for a nav badge.
    def unread_support_count
      conversation_ids = support_tickets.where.not(conversation_id: nil).distinct.pluck(:conversation_id)
      return 0 if conversation_ids.empty?

      Chats::Conversation.unread_counts_for(self, conversation_ids).values.sum
    end
  end
end
