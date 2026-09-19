# frozen_string_literal: true

require "rails/generators/base"

module SupportDesk
  module Generators
    # `rails generate support_desk:assistant Rose --disclosure signature` —
    # the harness, as files in YOUR app.
    #
    # The gem never calls a model. It emits `:assistant_turn` and it accepts
    # `respond!` / `draft!` / `escalate!` / `note!`; everything between those
    # two points — which provider, which prompt, which retries, what it
    # costs — is yours. This generator writes that middle: a job wired to
    # the event and a service with one method to fill in.
    #
    # Three things it deliberately does NOT do:
    #
    # * It never touches your initializer. `config.assistant` is a policy
    #   decision, and a generator that appends one turns "let me look at
    #   this" into a live assistant. The stanza is PRINTED; you paste it.
    # * It never overwrites. Run it again after an upgrade and it tells you
    #   which files it left alone.
    # * It copies no locales. The copy an assistant speaks in is the gem's
    #   (`support_desk.system.*`) until you override those keys in your own
    #   locale file, where they belong.
    #
    # `--disclosure` is required and has no default. Whether a customer is
    # told they are talking to a machine is not a thing a gem gets to decide
    # for a host in a jurisdiction it knows nothing about, so the generator
    # refuses to write anything until somebody has chosen.
    class AssistantGenerator < Rails::Generators::Base
      # The four modes, and what each one does to what the requester sees.
      DISCLOSURE_MODES = {
        "signature_and_notice" => "she signs every message AND the thread opens with a notice",
        "signature" => "she signs every message; no notice",
        "notice" => "the thread opens with a notice; her messages are unsigned, from the desk",
        "none" => "nothing is said and nothing is signed — your legal process has to be the one that chose this"
      }.freeze

      source_root File.expand_path("templates/assistant", __dir__)

      desc "Generate the harness for a support assistant: a turn job and a service"

      argument :name, type: :string, banner: "Rose",
               desc: "What she is called. Becomes her key (rose), her service and her job"

      class_option :disclosure, type: :string, required: false, banner: "MODE",
                   desc: "REQUIRED: #{DISCLOSURE_MODES.keys.join(" | ")}"
      class_option :desk, type: :string, default: "default",
                   desc: "The desk she works"
      class_option :autonomy, type: :string, default: "draft",
                   desc: AssistantPolicy::LEVELS.join(" | ")

      # Everything is checked BEFORE the first file is written. A generator
      # that writes two of its three files and then refuses the third leaves
      # an app that neither boots nor regenerates.
      def validate_options!
        @refused = true
        return say_disclosure_modes if options[:disclosure].blank?

        unless DISCLOSURE_MODES.key?(disclosure)
          say_status :error, "unknown disclosure #{options[:disclosure].inspect}", :red
          return say_disclosure_modes
        end
        unless AssistantPolicy::LEVELS.map(&:to_s).include?(autonomy)
          say_status :error, "unknown autonomy #{options[:autonomy].inspect} — one of " \
                             "#{AssistantPolicy::LEVELS.join(", ")}", :red
          return
        end

        @refused = false
      end

      def create_turn_job
        return if refused?

        template "turn_job.rb.erb", "app/jobs/support/#{key}_turn_job.rb", skip: true
      end

      def create_service
        return if refused?

        template "service.rb.erb", "app/services/support/#{key}.rb", skip: true
      end

      def create_job_test
        return if refused?

        template "turn_job_test.rb.erb", "test/jobs/support/#{key}_turn_job_test.rb", skip: true
      end

      # The four things a host still has to do by hand, in the order they
      # have to happen. Printed, never written: each one is a decision.
      def display_post_install_message
        return if refused?

        say "\n🤖 #{assistant_name}'s harness is in app/jobs/support/ and app/services/support/.", :green
        say "\n  Existing files were left alone — nothing here is ever overwritten."

        say "\n  1. Paste this into config/initializers/support_desk.rb, inside the configure block:"
        say "\n#{initializer_stanza}"

        say "  2. Subscribe the job to the one event the gem emits:"
        say "\n#{subscription_stanza}"

        say "  3. Schedule the two maintenance tasks. They are what makes a dead harness"
        say "     a delay instead of a customer nobody answers:"
        say "\n#{scheduler_stanza}"

        say "  4. Write #{service_class}.answer — it raises NotImplementedError until you do."
        say "     The README's Assistants section is the whole contract."

        say "\n  Then: SupportDesk.doctor.print, and start at --autonomy draft. Every word"
        say "  goes through a person until the numbers say otherwise.\n", :green
      end

      private

      def refused? = @refused

      # "Rose" → "rose"; "Customer Care" → "customer_care".
      def key = name.to_s.strip.underscore.parameterize(separator: "_")

      # What she is called, as typed — the `name` setting, not the key.
      def assistant_name = name.to_s.strip

      def service_class = "Support::#{key.camelize}"
      def job_class = "Support::#{key.camelize}TurnJob"
      def disclosure = options[:disclosure].to_s.strip
      def autonomy = options[:autonomy].to_s.strip
      def desk_key = options[:desk].to_s.strip.presence || "default"
      def default_desk? = desk_key == "default"

      def say_disclosure_modes
        say "\nsupport_desk:assistant needs --disclosure. Nothing was written.", :yellow
        say "\n  Whether a customer is told they are talking to a machine is a legal and"
        say "  product decision, and it is yours. The four modes:\n\n"
        DISCLOSURE_MODES.each { |mode, meaning| say "    --disclosure #{mode.ljust(21)} #{meaning}" }
        say "\n  rails g support_desk:assistant #{name} --disclosure signature\n\n"
      end

      def initializer_stanza
        lines = [
          "  config.assistant :#{key} do |#{key}|",
          "    #{key}.name       = #{assistant_name.inspect}",
          "    #{key}.autonomy   = :#{autonomy}",
          "    #{key}.disclosure = :#{disclosure}",
          "    #{key}.max_turns  = 6",
          "    #{key}.responds_within = 3.minutes",
          "    # #{key}.hand_off_when { |_ticket, message| " \
            "message.body.to_s.match?(/\\b(persona|humano|agente)\\b/i) }",
          "    # #{key}.cap { |ticket| :draft if ticket.requester.try(:vip?) }",
          "  end"
        ]
        lines << if default_desk?
          "  config.default_assistant = :#{key}"
        else
          "  config.desk(:#{desk_key}) { |desk| desk.assistant = :#{key} }"
        end
        "#{lines.join("\n")}\n\n"
      end

      def subscription_stanza
        <<~RUBY

            SupportDesk.on(:assistant_turn, key: "support.#{key}.turn") do |ticket, assistant, _message, turn:|
              #{job_class}.set(wait: 20.seconds).perform_later(ticket.id, assistant.key, turn)
            end

        RUBY
      end

      def scheduler_stanza
        <<~YAML

            # config/recurring.yml (solid_queue)
            production:
              support_desk_release_silent_assistants:
                command: "SupportDesk.release_silent_assistants!"
                schedule: every minute
              support_desk_redispatch_assistant_turns:
                command: "SupportDesk.redispatch_assistant_turns!"
                schedule: every 5 minutes

            # or cron
            * * * * * cd /app && bin/rails support_desk:release_silent_assistants
            */5 * * * * cd /app && bin/rails support_desk:redispatch_assistant_turns

        YAML
      end
    end
  end
end
