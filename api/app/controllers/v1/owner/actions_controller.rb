module V1
  module Owner
    class ActionsController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      def approve = control("approve_action")
      def stop = control("stop_action")
      def waive = control("waive_action")
      def mark_done = control("mark_action_done")
      def overturn = control("overturn_approval")

      private

      def control(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
