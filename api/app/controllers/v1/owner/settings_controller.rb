module V1
  module Owner
    class SettingsController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      def show
        render json: Leverage::Reads::WorkspaceSettings.call(current_caller.workspace_id)
      end

      def update
        run_command("change_workspace_settings", params: checked_body("change_workspace_settings"))
      end
    end
  end
end
