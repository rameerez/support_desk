# frozen_string_literal: true

module SupportDesk
  # The default Chats renderer uses the name/disclosure captured when an
  # assistant spoke. Host signature overrides remain authoritative. Human
  # replies (including approved drafts) still use Chats' normal signature.
  module MessageSignatures
    def message_signature_for(message)
      return super if config.message_signature || !message&.signed?

      stamp = message.metadata.is_a?(Hash) && message.metadata["support_desk"]
      return super unless stamp.is_a?(Hash) && stamp["kind"] == "ai" && stamp["signed"] == true

      name = stamp["display_name"]
      return super unless name.is_a?(String) && name.present?

      I18n.t("chats.message.signature", name: name)
    end
  end
end
