module Leverage
  module Transitions
    module Entries
      # sign_in (milestone 2 plan IN-5, IN-9, IN-11, IN-18): opens a session
      # for the owner the request names. The controller has already checked
      # the password, outside the pipeline, so a wrong one is 401 and stores
      # no commands row; the password is not in the request's params. The
      # session's token is returned once, in once, and only its digest is
      # kept. No event: sign-in changes nothing in the log (IF-17).
      class SignIn < Entry
        # Opens a session for user at ctx.at and sets the entry's result and
        # once: OwnerSession, split into its token-free part and its token.
        # create_owner opens the first session the same way.
        def self.open_session(ctx, user)
          token = Tokens.issue(:owner)
          session = Session.create!(workspace_id: user.workspace_id, user_id: user.id, token_hash: Tokens.digest(token),
            created_at: ctx.at, updated_at: ctx.at)
          [ { "user_id" => user.id, "created_at" => session.created_at.utc.iso8601(6) }, { "session_token" => token } ]
        end

        def load(ctx)
          @user = User.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id)
          raise NotFound, "No such owner" unless @user
        end

        def refusals(_ctx)
          [ state_refusal(nil) ].compact
        end

        def perform(ctx)
          @result, @once = self.class.open_session(ctx, @user)
        end
      end
    end
  end
end
