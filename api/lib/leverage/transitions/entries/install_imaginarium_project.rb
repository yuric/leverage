module Leverage
  module Transitions
    module Entries
      # install_imaginarium_project (DB-53, IM-6): the app creates the
      # Imaginarium project of a workspace made before create_owner did,
      # with project.created, as the app with no key. bin/rails
      # leverage:install_imaginarium_project applies it through
      # Timers.apply_workspace before the server starts. A workspace that
      # has one is refused invalid_state and gets nothing, so a second
      # start, or two at once, write the project once.
      class InstallImaginariumProject < Entry
        def refusals(ctx)
          causes = [ state_refusal(nil) ]
          if ctx.workspace.imaginarium_project_id
            causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal"))
          end
          causes.compact
        end

        def perform(ctx)
          Projects.create_imaginarium(ctx)
          @result = nil
        end
      end
    end
  end
end
