module Leverage
  module Transitions
    module Entries
      # create_owner (milestone 2 plan IN-2, IN-4, IN-9, IN-11; milestone 4
      # plan RD-1, RD-2): the first sign-in of an installation. In one
      # transaction, under the setup advisory lock (WorkspaceLock.take_setup,
      # because no workspace row exists to lock), it creates the workspace
      # with its default settings, the one owner with a bcrypt digest of the
      # password, a session whose token is returned once, and the seven
      # shipped rules, whose rule.created by the owner with the command's
      # key are the workspace's first events (L434, SM-33; this replaces
      # milestone 2's EN-4, a workspace with no rule). Allowed once: once any
      # owner exists, a new key is 404 not_found; a repeat of the key that
      # created it is answered by Idempotency before this entry runs.
      class CreateOwner < Entry
        # IN-4: a password has at least 8 characters.
        MINIMUM_PASSWORD_LENGTH = 8

        def load(ctx)
          raise NotFound, "The owner's sign-in already exists" if User.exists?

          @email_address = ctx.request.params.fetch("email_address")
          @password = ctx.request.params.fetch("password")
          return if @password.length >= MINIMUM_PASSWORD_LENGTH

          raise Invalid, "The password must have at least #{MINIMUM_PASSWORD_LENGTH} characters"
        end

        def refusals(_ctx)
          [ state_refusal(nil) ].compact
        end

        def perform(ctx)
          workspace = Workspace.create!(created_at: ctx.at, updated_at: ctx.at)
          ctx.use_workspace(workspace)
          user = User.create!(workspace_id: workspace.id, email_address: @email_address, password: @password,
            created_at: ctx.at, updated_at: ctx.at)
          ctx.caller_id = user.id
          RuleRecords.install_shipped(ctx)
          @result, @once = SignIn.open_session(ctx, user)
        end
      end
    end
  end
end
