module V1
  module Helper
    # The helper's calls about a seat the app runs (milestone 2 plan IN-11,
    # IN-17, PK-7, IF-21): the seat-token pickup for a start_seat request,
    # whose first answer carries the seat's fresh token once
    # (SeatTokenPickup), and the run-started and run-stopped reports. The
    # order of answers is IN-13's: 401, then the body (400 or 422), then
    # 404 for an id.
    class SeatsController < ApplicationController
      include AuthenticatesHelper
      include RunsCommands

      # POST /v1/helper/requests/{id}/seat-token: the id is the start_seat
      # request's.
      def seat_token
        checked_body("issue_seat_token")
        run_command("issue_seat_token", params: { "id" => uuid_param!(:id) })
      end

      # POST /v1/helper/seats/{id}/run-started
      def run_started = report("report_run_started")

      # POST /v1/helper/seats/{id}/run-stopped
      def run_stopped = report("report_run_stopped")

      private

      def report(command)
        run_command(command, params: checked_body(command).merge("id" => uuid_param!(:id)))
      end
    end
  end
end
