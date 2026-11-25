module V1
  module Agent
    # GET /v1/commands/{key} (get_command): the outcome of a command this
    # seat sent, as the contract's CommandOutcome. Reading it marks it read,
    # which clears `command` in GET /v1/next (DB-34). A key that is not of
    # the form every stored key has (Idempotency.valid_key?) names no
    # command: 404 without a look, so a NUL in the path never reaches the
    # database.
    class CommandsController < ApplicationController
      include AuthenticatesSeat

      def show
        key = params[:key].to_s
        found = Leverage::Idempotency.valid_key?(key) && Leverage::Reads::CommandOutcome.call(
          workspace_id: current_seat.workspace_id, caller_kind: current_caller.kind, caller_id: current_caller.id, key: key)
        raise NotFound, "No such command" unless found

        Leverage::Transitions::MarkRead.command(found.row)
        render json: RunsCommands.outcome_body(found.row.command, found.row.key, found.outcome)
      end
    end
  end
end
