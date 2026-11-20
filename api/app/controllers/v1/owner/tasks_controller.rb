module V1
  module Owner
    # The owner's task calls: add a task, complete its contract, cancel it,
    # allow one more round, and read its page (milestone 2 plan SC-1, SC-9).
    #
    # A command checks its body against the contract's schema (400 malformed,
    # 422 invalid), then its path id (404), and then runs the entry with the
    # body and the id as params (IN-13).
    class TasksController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      def show
        page = Leverage::Reads::TaskPage.call(current_caller.workspace_id, uuid_param!(:id))
        raise NotFound, "No such task" unless page

        render json: page
      end

      def create
        run_command("add_task", params: checked_body("add_task"))
      end

      def complete_contract
        run_command("complete_contract", params: checked_body("complete_contract").merge("id" => uuid_param!(:id)))
      end

      def cancel
        run_command("cancel", params: checked_body("cancel_task").merge("id" => uuid_param!(:id)))
      end

      def allow_another_round
        run_command("allow_another_round", params: checked_body("allow_another_round").merge("id" => uuid_param!(:id)))
      end

      # The owner's controls of milestone 3 (plan HE-24, HE-25): Add task
      # into the Backlog from the Imaginarium, Edit contract (the Complete
      # contract body), and hold and resume.
      def promote = control("promote_task", "promote")
      def contract = control("edit_contract", "edit_contract")
      def hold = control("hold_task", "hold")
      def resume = control("resume_task", "resume")

      private

      # operation_id names the body to check, command the entry to run.
      def control(operation_id, command)
        run_command(command, params: checked_body(operation_id).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
