# frozen_string_literal: true

module SupportDesk
  # chats finds every conversation a request names (the thread, a dock
  # window, the composer, read, typing, refresh, reactions, edits) by asking,
  # in order, the relations `Chats::ApplicationController#conversation_lookup_scopes`
  # returns (chats >= 0.5.1). By default that is the viewer's inbox,
  # `Messager#chats`, with the host's `config.inbox_scope` applied: the right
  # rule for a list and the wrong one for a case. A host that keeps support
  # apart from its inbox (`thread_page = :support`, and an inbox_scope that
  # leaves SupportDesk::Ticket conversations out) would 404 its requesters
  # inside their own cases.
  #
  # So this adds one relation after chats' own: the viewer's own cases
  # (SupportDesk::Ticket.conversations_of), through the same participation
  # and block rules as the inbox, without the host's listing scope. The union
  # of the scopes is the authorization: nobody gains a conversation they are
  # not seated in, a non-support conversation the host hides stays hidden, and
  # a layer of the host's that refuses a conversation (its own
  # `find_conversation`, or a scope it drops) still refuses it.
  #
  # Prepended to Chats::ApplicationController by the engine, in `to_prepare`
  # so it survives a code reload.
  module ConversationAccess
    protected

    def conversation_lookup_scopes
      super + [ SupportDesk::Ticket.conversations_of(chats_current_messager) ]
    end
  end
end
