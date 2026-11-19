module V1
  module Agent
    # GET /v1/commands/{key} (get_command): the outcome of a command this
    # seat sent, as the contract's CommandOutcome. Reading it marks it read,
    # which clears `command` in GET /v1/next (DB-34).
    class CommandsController < ApplicationController
      include AuthenticatesSeat

      def show
        found = Leverage::Reads::CommandOutcome.call(workspace_id: current_seat.workspace_id, caller_kind: current_caller.kind,
          caller_id: current_caller.id, key: params[:key].to_s)
        raise NotFound, "No such command" unless found

        Leverage::Transitions::MarkRead.command(found.row)
        render json: RunsCommands.outcome_body(found.row.command, found.row.key, found.outcome)
      end
    end
  end
end
