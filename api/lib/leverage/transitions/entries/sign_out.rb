module Leverage
  module Transitions
    module Entries
      # sign_out (milestone 2 plan IN-5, IN-9): deletes the session the
      # bearer token named, so the token answers 401 from then on. It stores
      # a commands row like any mutating call; a repeat of its key answers
      # 401 at sign-in, because the session that would prove who asks is the
      # one this call ended. No event.
      class SignOut < Entry
        # The session is already gone (a sign-out of the same session that
        # committed first): the caller is no longer signed in, so the
        # controller answers 401 and nothing is written.
        class SessionEnded < StandardError; end

        def load(ctx)
          @session = Session.find_by(id: ctx.request.params["session_id"], user_id: ctx.request.caller_id,
            workspace_id: ctx.workspace.id)
          raise SessionEnded, "The session has ended" unless @session
        end

        def refusals(_ctx)
          [ state_refusal(nil) ].compact
        end

        def perform(_ctx)
          @session.destroy!
          @result = {}
        end
      end
    end
  end
end
