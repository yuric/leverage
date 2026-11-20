module V1
  module Owner
    # The owner's rule calls (milestone 4 plan §2.1, §2.3, RD-26): the list of
    # rules with their current versions, and add, save, switch on and off,
    # revert and remove.
    #
    # A command checks its body against the contract's schema (400
    # malformed, 422 invalid), then its path id (404), and then runs the
    # entry with the body and the id as params (IN-13). Which rules the owner
    # may change, and what each change writes, is the entries'.
    class RulesController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      # GET /v1/owner/rules: a read, with no key.
      def index
        render json: Leverage::Reads::Rules.call(current_caller.workspace_id)
      end

      def create = run_command("add_rule", params: checked_body("add_rule"))

      # POST /v1/owner/rules/{id}/versions
      def versions = control("save_rule")

      def enable = control("enable_rule")
      def disable = control("disable_rule")
      def revert = control("revert_rule")
      def remove = control("remove_rule")

      private

      # The operation's id is also its command's name.
      def control(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
