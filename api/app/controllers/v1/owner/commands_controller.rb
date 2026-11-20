module V1
  module Owner
    # GET /v1/owner/commands/{key} (get_owner_command): the stored outcome
    # of a command this owner sent under that key (IF-4). A key that was
    # never sent, or was sent by another caller or in another workspace, is
    # 404. A command whose first answer carried a token answers its
    # token-free result with "repeated": true (IN-11).
    class CommandsController < ApplicationController
      include AuthenticatesOwner

      def show
        row = Command.find_by(workspace_id: current_caller.workspace_id, caller_kind: "owner", caller_id: current_caller.id,
          key: params[:key].to_s)
        raise NotFound, "No command was sent under this key" unless row

        render json: RunsCommands.outcome_body(row.command, row.key, Leverage::Idempotency.outcome_of(row))
      end
    end
  end
end
