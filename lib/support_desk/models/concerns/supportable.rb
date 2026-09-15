# frozen_string_literal: true

module SupportDesk
  # Included by `supportable`. Every method has a working default; override
  # the ones that matter to you:
  #
  #   class Ride < ApplicationRecord
  #     supportable topic: :ride
  #
  #     def support_label  = "#{origin} → #{destination} · #{departs_on.to_fs(:short)}"
  #     def support_status = status_pill&.label
  #     def support_context = { "Conductor" => driver.public_name, "Plazas" => seats }
  #     def support_url    = Rails.application.routes.url_helpers.madmin_ride_path(self)
  #     def supportable_by?(requester) = participants.exists?(user: requester)
  #   end
  module Supportable
    extend ActiveSupport::Concern

    included do
      class_attribute :support_desk_supportable_options, instance_writer: false,
                                                         default: { topic: nil, candidates: nil,
                                                                    one_open_ticket: true }.freeze

      has_many :support_tickets,
               class_name: "SupportDesk::Ticket",
               as: :subject,
               inverse_of: :subject,
               dependent: :nullify
    end

    class_methods do
      # True — this class is supportable. (The predicate exists on the class
      # AND the instance so config validation, doors and pickers can ask
      # either one.)
      def supportable? = true

      # The records the "which one?" picker offers +requester+: the
      # `candidates:` proc when given, else the requester's own association
      # by this model's plural name, else none.
      def support_candidates_for(requester)
        proc = support_desk_supportable_options[:candidates]
        return proc.call(requester) if proc.respond_to?(:call)

        association = model_name.plural
        return requester.public_send(association) if requester.respond_to?(association)

        none
      end

      # Whether a requester may hold only one open ticket about a given
      # record of this class.
      def one_open_support_ticket? = support_desk_supportable_options[:one_open_ticket]
    end

    def supportable? = true

    # The topic a ticket opened about this record lands on.
    def support_topic
      self.class.support_desk_supportable_options[:topic]
    end

    # How this record is named in ticket labels, context cards and the
    # opening notice.
    def support_label
      "#{self.class.model_name.human} #{id}"
    end

    # A short status pill rendered under the label, in the picker and the
    # console. nil renders nothing.
    def support_status = nil

    # Key/value pairs an agent sees in the console's context card. Rendered
    # to agents only — you decide what belongs there.
    def support_context = {}

    # Where an agent can open this record in your admin. nil renders no link.
    def support_url = nil

    # May +requester+ open a ticket about this record? The default is the
    # obvious ownership check; override it for anything else.
    def supportable_by?(requester)
      return false if requester.nil?

      respond_to?(:user) && user == requester
    end
  end
end
