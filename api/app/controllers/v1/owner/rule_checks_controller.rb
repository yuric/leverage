module V1
  module Owner
    # The owner's two calls on one check of a rule (milestone 4 plan §2.1,
    # §2.3): run it again, or override it for its task with a reason. The
    # path's id is the check's; whether it may be run again or overridden
    # now is the entry's.
    class RuleChecksController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      # POST /v1/owner/rule-checks/{id}/rerun
      def rerun = control("rerun_check")

      # POST /v1/owner/rule-checks/{id}/override
      def override = control("override_check")

      private

      # The operation's id is also its command's name.
      def control(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
